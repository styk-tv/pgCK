//! pgCK NATS client (S4 canonical path).
//!
//! Lives only under `nats-client` feature. Spins up a tokio runtime on
//! a dedicated thread, owns an `async_nats::Client` connected to the
//! bundled / cluster `nats-server` (per `pgck.nats_url` GUC), and
//! exposes a synchronous publish API the LISTEN/NOTIFY drain calls into.
//!
//! Architecture per SPEC.PGCK.NATS-BIDIRECTIONAL.v0.2 §3 / §4 and
//! TASKS.PGCK.S4-BUNDLED-NATS.v0.1 step 2:
//!
//!   pgrx side (any PG backend thread)
//!     │
//!     │ nats_client::publish(subject, payload, headers)
//!     ▼
//!   mpsc::SyncSender<Cmd>  ──►  tokio thread (single-thread runtime)
//!                                  │
//!                                  │ rx.recv() → match cmd
//!                                  ▼
//!                          async_nats::Client::publish_with_headers
//!                                  │
//!                                  ▼
//!                          bundled nats-server (127.0.0.1:4222 default)
//!
//! Publish is fire-and-forget for the caller. NATS Core publish failures
//! log via stderr and continue (lossy at the publish edge by design —
//! see rc-09-nats §4.2). JetStream publish requires `pgck.nats_js_stream`
//! GUC to be non-empty; failures there log but do not panic.

use std::sync::mpsc;
use std::sync::OnceLock;

#[derive(Debug)]
enum Cmd {
    Publish {
        subject: String,
        payload: Vec<u8>,
        headers: Vec<(String, String)>,
    },
    PublishJs {
        subject: String,
        payload: Vec<u8>,
        headers: Vec<(String, String)>,
    },
}

struct ClientHandle {
    tx: mpsc::SyncSender<Cmd>,
}

static CLIENT: OnceLock<ClientHandle> = OnceLock::new();
static RELAY_STARTED: OnceLock<()> = OnceLock::new();

/// Inbound subject the relay subscribes to, and the prefix it strips to
/// derive the fan-out event subject. A browser publishes
/// `input.kernel.pgCK.action.<verb>`; the relay re-emits
/// `event.kernel.pgCK.<verb>` so every subscribed browser receives it.
///
/// This is a GOVERNANCE-FREE transport relay (G2 minimal: basic Bob<->Alice
/// communication + presence). It does NOT seal, validate, or resolve
/// affordances. When the governed dispatcher lands (CKA-4), this handler
/// becomes the seam: input -> resolve affordance -> validate -> seal -> event.
const RELAY_IN_SUBJECT: &str = "input.kernel.pgCK.action.>";
const RELAY_IN_PREFIX: &str = "input.kernel.pgCK.action.";
const RELAY_OUT_PREFIX: &str = "event.kernel.pgCK.";

/// Identity-scoped inbound (hop 4, subject-scoping): the auth-callout grants a
/// verified connection publish ONLY on `input.kernel.pgCK.id.<its-own-sub>.action.>`,
/// so the `<sub>` segment the relay reads here is broker-enforced, never claimed.
const RELAY_ID_SUBJECT: &str = "input.kernel.pgCK.id.*.action.>";

/// The NATS auth-callout request subject pgCK answers on when it owns admittance
/// (`pgck.nats_account_seed` set). SPEC.OAUTH2 §3.2.
const CALLOUT_SUBJECT: &str = "$SYS.REQ.USER.AUTH";

/// Material the relay thread needs to serve the pgCK-owned auth-callout responder.
/// Built on the bgworker thread (which owns GUC access) and moved into the relay
/// thread — the async side never touches pg.
pub struct CalloutContext {
    /// Latched realm verifier config (`pgck.oidc_*`); `None` ⇒ every admission is
    /// anonymous (fail-open-to-anonymous, never-to-admitted).
    pub auth: Option<&'static crate::jwt_verify::AuthConfig>,
    /// The callout account signing key (`pgck.nats_account_seed`).
    pub account: nkeys::KeyPair,
}

/// Initialise the NATS client thread. Idempotent — subsequent calls are
/// no-ops. Called once from the bgworker's tick loop (S4 step 5).
///
/// `url` is the NATS endpoint to dial (e.g. `nats://127.0.0.1:4222`).
/// `js_stream` is the JetStream stream name; `None` skips the JS arm.
pub fn init(url: String, js_stream: Option<String>) {
    if CLIENT.get().is_some() {
        return;
    }
    let (tx, rx) = mpsc::sync_channel::<Cmd>(1024);
    if CLIENT.set(ClientHandle { tx }).is_err() {
        return;
    }
    std::thread::spawn(move || run_client_thread(url, js_stream, rx));
}

/// Publish to NATS Core (the bundled `nats-server`'s live-subscriber path).
/// Fire-and-forget — returns once the command is queued, not when it lands.
///
/// `headers` is a slice of `(name, value)` pairs that get serialised
/// into a NATS header block (`HPUB` wire form on async-nats's side).
/// pgCK always stamps at least `Ck-Seq: <ledger.seq>` per CK.Lib.Js v1.3
/// client-side dedup.
pub fn publish(subject: &str, payload: &[u8], headers: &[(String, String)]) -> Result<(), String> {
    let handle = CLIENT.get().ok_or("nats client not initialised")?;
    handle
        .tx
        .send(Cmd::Publish {
            subject: subject.to_string(),
            payload: payload.to_vec(),
            headers: headers.to_vec(),
        })
        .map_err(|e| format!("nats publish enqueue failed: {e}"))
}

/// Publish to a JetStream stream (the bundled / cluster `nats-server`'s
/// durable path). No-op (returns error) if the runtime was initialised
/// without a stream name.
///
/// pgCK stamps `Nats-Msg-Id: <ledger.seq>` here so the JS stream's
/// dedup window deduplicates retries of the same governed write.
pub fn publish_js(
    subject: &str,
    payload: &[u8],
    headers: &[(String, String)],
) -> Result<(), String> {
    let handle = CLIENT.get().ok_or("nats client not initialised")?;
    handle
        .tx
        .send(Cmd::PublishJs {
            subject: subject.to_string(),
            payload: payload.to_vec(),
            headers: headers.to_vec(),
        })
        .map_err(|e| format!("js publish enqueue failed: {e}"))
}

/// Start the inbound relay thread. Idempotent. Subscribes the governed-write
/// subjects (`input.kernel.pgCK.action.>` + the identity-scoped
/// `input.kernel.pgCK.id.*.action.>`) on its own async-nats connection and
/// enqueues each action for the bgworker's SPI dispatch (F1-inbound), replying
/// on `result.kernel.pgCK.<verb>`. Independent of the publish thread (`init`).
///
/// When `callout` is provided, the same connection also serves the pgCK-owned
/// auth-callout responder on `$SYS.REQ.USER.AUTH` (SPEC.OAUTH2 §3.2) — verify
/// the CONNECT token, mint the scoped user-JWT, sign with the account key.
pub fn init_relay(url: String, callout: Option<CalloutContext>) {
    if RELAY_STARTED.get().is_some() {
        return;
    }
    if RELAY_STARTED.set(()).is_err() {
        return;
    }
    std::thread::spawn(move || run_relay_thread(url, callout));
}

/// Derive the fan-out event subject from an inbound action subject.
/// `input.kernel.pgCK.action.session.join` -> `event.kernel.pgCK.session.join`.
/// Returns `None` if the subject is not under the relay prefix. (Retained for the
/// verb-parse contract test; the live path now dispatches via inbound_dispatch.)
#[allow(dead_code)]
fn relay_subject(inbound: &str) -> Option<String> {
    inbound
        .strip_prefix(RELAY_IN_PREFIX)
        .map(|verb| format!("{RELAY_OUT_PREFIX}{verb}"))
}

/// Extract `user:pass` credentials from a NATS URL's userinfo. async-nats 0.48
/// builds CONNECT auth ONLY from `ConnectOptions` — it never reads the URL's
/// userinfo — so `pgck.nats_url = nats://pgck_worker:<pw>@host:4222` (the worker
/// as an `auth_users` member behind the callout) must be extracted by us.
/// `Some` only when both user and password are present and the user is non-empty.
fn url_credentials(url: &str) -> Option<(String, String)> {
    let addr: async_nats::ServerAddr = url.parse().ok()?;
    match (addr.username(), addr.password()) {
        (Some(user), Some(pass)) if !user.is_empty() => Some((user.to_string(), pass.to_string())),
        _ => None,
    }
}

/// Connect to NATS honoring URL userinfo, retrying until the broker answers.
/// Container starts race pg against nats-server — a one-shot connect failure
/// would kill the calling thread (and with it the relay or the drain) for the
/// whole process lifetime, so keep dialing with capped backoff instead.
async fn connect_with_retry(who: &str, url: &str) -> async_nats::Client {
    let opts = match url_credentials(url) {
        Some((user, pass)) => async_nats::ConnectOptions::new().user_and_password(user, pass),
        None => async_nats::ConnectOptions::new(),
    };
    let mut delay = std::time::Duration::from_secs(1);
    loop {
        match opts.clone().connect(url).await {
            Ok(c) => return c,
            Err(e) => {
                eprintln!(
                    "pgck {who}: connect to {url} failed: {e} — retrying in {}s",
                    delay.as_secs()
                );
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(std::time::Duration::from_secs(15));
            }
        }
    }
}

/// A routed inbound action: the verb, where the typed reply goes, and the
/// broker-enforced identity (if the subject carried the id scope).
#[derive(Debug, PartialEq)]
struct RoutedInbound {
    /// `Some(sub)` when routed from `input.kernel.pgCK.id.<sub>.action.<verb>` —
    /// the callout granted publish ONLY on the connection's own `<sub>` segment,
    /// so the value is broker-enforced (subject-scoping, SPEC.SECURITY hop 4).
    identity: Option<String>,
    verb: String,
    result_subject: String,
}

/// Route an inbound subject to its dispatch shape (F1-inbound, hop 4).
///
/// - `input.kernel.pgCK.action.<verb>`            → anonymous dispatch
/// - `input.kernel.pgCK.id.<sub>.action.<verb>`   → dispatch as `<sub>` (verified)
///
/// `<sub>` is a single NATS token; the verb is non-empty. Anything else is `None`.
fn route_inbound(subject: &str) -> Option<RoutedInbound> {
    const ID_PREFIX: &str = "input.kernel.pgCK.id.";
    let (identity, verb) = if let Some(rest) = subject.strip_prefix(ID_PREFIX) {
        // `<sub>` is exactly one token: split at the FIRST dot and require the
        // literal `action.` right after — a dotted sub can't smuggle past its grant.
        let (sub, after) = rest.split_once('.')?;
        if sub.is_empty() {
            return None;
        }
        (Some(sub.to_string()), after.strip_prefix("action.")?)
    } else {
        (None, subject.strip_prefix(RELAY_IN_PREFIX)?)
    };
    if verb.is_empty() {
        return None;
    }
    Some(RoutedInbound {
        identity,
        verb: verb.to_string(),
        result_subject: format!("result.kernel.pgCK.{verb}"),
    })
}

/// Extract the correlation headers to echo on a `result.*` reply. Only the
/// client's `Trace-Id` (request/reply correlation, LLD §7) and `Ck-Seq` are
/// carried — a stable subset that avoids depending on HeaderMap iteration order.
fn trace_headers(h: &async_nats::HeaderMap) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for key in ["Trace-Id", "Ck-Seq"] {
        if let Some(v) = h.get(key) {
            out.push((key.to_string(), v.to_string()));
        }
    }
    out
}

fn run_relay_thread(url: String, callout: Option<CalloutContext>) {
    use futures_util::StreamExt;

    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("pgck nats-relay: failed to build tokio runtime: {e}");
            return;
        }
    };

    runtime.block_on(async move {
        let client = connect_with_retry("nats-relay", &url).await;

        // Admittance first: if pgCK owns the callout, serve it before any inbound
        // action can arrive on the identity-scoped subjects it grants.
        if let Some(ctx) = callout {
            let c = client.clone();
            tokio::spawn(async move { run_callout(c, ctx).await });
        }

        let legacy = match client.subscribe(RELAY_IN_SUBJECT).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("pgck nats-relay: subscribe {RELAY_IN_SUBJECT} failed: {e}");
                return;
            }
        };
        let scoped = match client.subscribe(RELAY_ID_SUBJECT).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("pgck nats-relay: subscribe {RELAY_ID_SUBJECT} failed: {e}");
                return;
            }
        };
        let mut sub = futures_util::stream::select(legacy, scoped);
        eprintln!(
            "pgck nats-relay: relaying {RELAY_IN_SUBJECT} + {RELAY_ID_SUBJECT} -> ckp.dispatch"
        );

        while let Some(msg) = sub.next().await {
            // F1-inbound (CKA-4): the SPI-bound governed dispatch can't run on this
            // async thread — enqueue for the bgworker tick to run ckp.dispatch and
            // reply on result.kernel.pgCK.<verb>. The identity (if any) comes from
            // the broker-enforced subject segment, never a payload/header claim.
            let Some(routed) = route_inbound(msg.subject.as_str()) else {
                continue;
            };
            let headers = msg.headers.as_ref().map(trace_headers).unwrap_or_default();
            crate::inbound_dispatch::enqueue(crate::inbound_dispatch::InboundAction {
                verb: routed.verb,
                payload: msg.payload.to_vec(),
                result_subject: routed.result_subject,
                headers,
                identity: routed.identity,
            });
        }
        eprintln!("pgck nats-relay: inbound subscription ended");
    });
}

/// The auth-callout responder loop (SPEC.OAUTH2 §3.2, hop 3). Pure per-request:
/// decode → verify (in-memory JWK, no egress) → mint scoped user-JWT → signed
/// AuthorizationResponse to the request's reply inbox. Fail-open-to-anonymous,
/// never-to-admitted (SPEC.SECURITY §7.2).
async fn run_callout(client: async_nats::Client, ctx: CalloutContext) {
    use futures_util::StreamExt;

    let mut sub = match client.subscribe(CALLOUT_SUBJECT).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("pgck auth-callout: subscribe {CALLOUT_SUBJECT} failed: {e}");
            return;
        }
    };
    eprintln!(
        "pgck auth-callout: responder live on {CALLOUT_SUBJECT} (token verify: {})",
        if ctx.auth.is_some() {
            "realm-jwk"
        } else {
            "off -> anonymous"
        }
    );

    while let Some(msg) = sub.next().await {
        let Some(reply) = msg.reply else {
            continue; // not a request — nothing to admit
        };
        let Ok(request_jwt) = std::str::from_utf8(&msg.payload) else {
            continue;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let response =
            crate::auth_callout::handle_request(request_jwt, ctx.auth, &ctx.account, now);
        if let Err(e) = client.publish(reply, response.into_bytes().into()).await {
            eprintln!("pgck auth-callout: response publish failed: {e}");
        }
        // The connect handshake blocks on this response — flush, don't buffer.
        if let Err(e) = client.flush().await {
            eprintln!("pgck auth-callout: flush failed: {e}");
        }
    }
    eprintln!("pgck auth-callout: subscription ended");
}

fn run_client_thread(url: String, js_stream: Option<String>, rx: mpsc::Receiver<Cmd>) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("pgck nats-client: failed to build tokio runtime: {e}");
            return;
        }
    };

    runtime.block_on(async move {
        let client = connect_with_retry("nats-client", &url).await;
        eprintln!("pgck nats-client: connected to {url}");

        let jetstream = js_stream
            .as_ref()
            .map(|_| async_nats::jetstream::new(client.clone()));

        while let Ok(cmd) = rx.recv() {
            match cmd {
                Cmd::Publish {
                    subject,
                    payload,
                    headers,
                } => {
                    let hm = build_headers(&headers);
                    if let Err(e) = client
                        .publish_with_headers(subject.clone(), hm, payload.into())
                        .await
                    {
                        eprintln!(
                            "pgck nats-client: core publish failed: subject={subject} err={e}"
                        );
                    }
                    // The command loop blocks on a sync mpsc recv() inside the
                    // single-thread runtime, which starves async-nats's
                    // background flusher — so an un-flushed publish would sit
                    // buffered and never reach the server. Flush explicitly.
                    if let Err(e) = client.flush().await {
                        eprintln!("pgck nats-client: flush failed: subject={subject} err={e}");
                    }
                }
                Cmd::PublishJs {
                    subject,
                    payload,
                    headers,
                } => {
                    let Some(ref js) = jetstream else {
                        eprintln!(
                            "pgck nats-client: js publish called but no js_stream configured \
                             — payload dropped: subject={subject}"
                        );
                        continue;
                    };
                    let hm = build_headers(&headers);
                    match js
                        .publish_with_headers(subject.clone(), hm, payload.into())
                        .await
                    {
                        Ok(ack) => {
                            if let Err(e) = ack.await {
                                eprintln!(
                                    "pgck nats-client: js publish ack failed: \
                                     subject={subject} err={e}"
                                );
                            }
                        }
                        Err(e) => {
                            eprintln!(
                                "pgck nats-client: js publish failed: subject={subject} err={e}"
                            );
                        }
                    }
                }
            }
        }
    });
}

fn build_headers(pairs: &[(String, String)]) -> async_nats::HeaderMap {
    let mut hm = async_nats::HeaderMap::new();
    for (name, value) in pairs {
        hm.append(name.as_str(), value.as_str());
    }
    hm
}

#[cfg(test)]
mod tests {
    use super::{relay_subject, route_inbound, url_credentials};

    #[test]
    fn url_credentials_extracts_userinfo() {
        let creds = url_credentials("nats://pgck_worker:s3cr3t@127.0.0.1:4222");
        assert_eq!(
            creds,
            Some(("pgck_worker".to_string(), "s3cr3t".to_string()))
        );
    }

    #[test]
    fn url_credentials_none_without_userinfo() {
        assert_eq!(url_credentials("nats://127.0.0.1:4222"), None);
        // user without a password is not a usable user/pass pair
        assert_eq!(url_credentials("nats://only-user@127.0.0.1:4222"), None);
        // unparseable URL → no credentials (connect will surface its own error)
        assert_eq!(url_credentials("not a url"), None);
    }

    #[test]
    fn relay_subject_maps_action_to_event() {
        assert_eq!(
            relay_subject("input.kernel.pgCK.action.session.join").as_deref(),
            Some("event.kernel.pgCK.session.join")
        );
        assert_eq!(
            relay_subject("input.kernel.pgCK.action.task.create").as_deref(),
            Some("event.kernel.pgCK.task.create")
        );
    }

    #[test]
    fn relay_subject_rejects_non_action_subjects() {
        assert_eq!(relay_subject("event.kernel.pgCK.x"), None);
        assert_eq!(relay_subject("input.kernel.other.action.x"), None);
    }

    #[test]
    fn route_inbound_legacy_action_subject_is_anonymous() {
        let r = route_inbound("input.kernel.pgCK.action.task.create").expect("routes");
        assert_eq!(r.identity, None);
        assert_eq!(r.verb, "task.create");
        assert_eq!(r.result_subject, "result.kernel.pgCK.task.create");
    }

    #[test]
    fn route_inbound_id_scoped_subject_carries_the_broker_enforced_sub() {
        let sub = "some-verified-sub"; // synthetic — never a captured identity
        let r = route_inbound(&format!("input.kernel.pgCK.id.{sub}.action.task.create"))
            .expect("routes");
        assert_eq!(r.identity.as_deref(), Some(sub));
        assert_eq!(r.verb, "task.create");
        assert_eq!(r.result_subject, "result.kernel.pgCK.task.create");
    }

    #[test]
    fn route_inbound_rejects_malformed_subjects() {
        // empty sub token
        assert_eq!(route_inbound("input.kernel.pgCK.id..action.x"), None);
        // id scope without the action segment
        assert_eq!(route_inbound("input.kernel.pgCK.id.someone.x"), None);
        // id scope with sub but nothing after action.
        assert_eq!(route_inbound("input.kernel.pgCK.id.someone.action."), None);
        // empty verb on the legacy form
        assert_eq!(route_inbound("input.kernel.pgCK.action."), None);
        // foreign prefixes
        assert_eq!(route_inbound("event.kernel.pgCK.Task.sealed"), None);
        assert_eq!(
            route_inbound("input.kernel.other.id.someone.action.x"),
            None
        );
    }

    #[test]
    fn route_inbound_sub_is_a_single_token_never_a_wildcard_capture() {
        // A dotted "sub" would mean the publisher escaped its grant — the parse
        // must not let `<sub>` swallow extra tokens to find an `action` later.
        assert_eq!(
            route_inbound("input.kernel.pgCK.id.a.b.action.task.create"),
            None
        );
    }
}
