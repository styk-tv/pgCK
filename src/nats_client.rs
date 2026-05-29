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
        let client = match async_nats::connect(url.as_str()).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("pgck nats-client: connect to {url} failed: {e}");
                return;
            }
        };
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
