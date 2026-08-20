//! NATS auth-callout responder — pgCK-owned admittance (SPEC.OAUTH2 §3.2/§3.3).
//!
//! pgCK IS the verifier (Option A). On each connection NATS publishes an
//! authorization request to `$SYS.REQ.USER.AUTH`; this module:
//!   1. decodes the request and pulls the CONNECT `auth_token` (the Keycloak JWT),
//!   2. verifies it in-memory via [`crate::jwt_verify`] (env-delivered JWKS, no egress),
//!   3. mints a signed NATS user-JWT scoped by pgCK governance — a *verified*
//!      identity may dispatch; an absent/foreign/expired token drops to anonymous
//!      (subscribe-only), never admitted with a client-claimed identity,
//!   4. wraps it in a signed AuthorizationResponse the broker admits with.
//!
//! The realm JWT verifier ([`crate::jwt_verify`], F1) is a dependency this module
//! CALLS, never edits. The NATS-side signing key is a separate account NKey
//! (`pgck.nats_account_seed`, env-delivered like the OIDC GUCs).

use crate::jwt_verify::{callout_identity, Admission, AuthConfig};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use nkeys::KeyPair;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// The reply inbox is kernel-independent (NATS mints `_INBOX.<nuid>` per
/// connection), so it is the one subject that is not parameterised over a
/// kernel. Event/result/input subjects ARE per-kernel and are derived from the
/// configured kernel set — see [`permissions_for`] (pgCK#30).
const INBOX_SUBJECT: &str = "_INBOX.>";

/// The subjects a connection reads/writes on ONE kernel `k`, per tier.
fn event_subject(k: &str) -> String {
    format!("event.kernel.{k}.>")
}
fn result_subject(k: &str) -> String {
    format!("result.kernel.{k}.>")
}
fn input_subject(k: &str, sub_token: &str) -> String {
    format!("input.kernel.{k}.id.{sub_token}.action.>")
}

/// NATS subject permissions minted for a connection.
#[derive(Debug, Clone, PartialEq)]
pub struct UserPermissions {
    /// Subjects the connection may publish to. Empty ⇒ deny all publish.
    pub pub_allow: Vec<String>,
    /// Subjects the connection may subscribe to.
    pub sub_allow: Vec<String>,
}

/// Sanitize a verified `sub` into a single NATS subject token: `[A-Za-z0-9_-]`
/// kept, every other byte → `-`, empty → `-`. UUID subs (the realm's form) pass
/// unchanged, so the token round-trips into `ckp.requester` losslessly there.
fn subject_token(sub: &str) -> String {
    let t: String = sub
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    if t.is_empty() {
        "-".to_string()
    } else {
        t
    }
}

/// Governance-derived admittance permissions (SPEC.OAUTH2 §5 Tier 2, subject-scoped
/// per SPEC.SECURITY hop 4), minted over the deployment's configured kernel set
/// `kernels` — NEVER a hardcoded `pgCK` literal (pgCK#30). A `demo` or
/// `Dictionary` deployment thus grants on its OWN kernel's subjects. The set is
/// the kernels the DEPLOYMENT hosts; narrowing to the kernels a given identity is
/// entitled to is the authority-chain's job (F-group), not the transport gate's.
/// - **Verified** — may DISPATCH on its own identity-scoped subject
///   `input.kernel.<k>.id.<sub-token>.action.>` for each `k` — the broker thereby
///   enforces the `<sub>` segment the F1-inbound bridge binds to `ckp.requester`.
///   Plus read: events + results per kernel + its own inbox.
/// - **Anonymous** — subscribe-only on each kernel's event stream; NO publish.
///
/// An empty `kernels` yields no kernel-scoped grants (a misconfigured deployment
/// admits nothing rather than silently falling back to a literal) — the caller
/// defaults the set from config, so this is the fail-closed floor, not the norm.
pub fn permissions_for(admission: &Admission, kernels: &[String]) -> UserPermissions {
    match admission {
        Admission::Verified { sub, .. } => {
            let token = subject_token(sub);
            let mut pub_allow = Vec::with_capacity(kernels.len());
            let mut sub_allow = Vec::with_capacity(kernels.len() * 2 + 1);
            for k in kernels {
                pub_allow.push(input_subject(k, &token));
                sub_allow.push(event_subject(k));
                sub_allow.push(result_subject(k));
            }
            sub_allow.push(INBOX_SUBJECT.to_string());
            UserPermissions {
                pub_allow,
                sub_allow,
            }
        }
        Admission::Anonymous => UserPermissions {
            pub_allow: vec![], // deny all publish
            sub_allow: kernels.iter().map(|k| event_subject(k)).collect(),
        },
    }
}

/// Parse the env/GUC-delivered NATS account seed (`SA…`) into the callout's
/// response-signing [`KeyPair`]. Trims whitespace (conf-file delivery). Returns
/// `None` for anything that is not a valid ACCOUNT seed — a user/server/operator
/// seed must not silently become the callout issuer.
pub fn parse_account_seed(seed: &str) -> Option<KeyPair> {
    let kp = KeyPair::from_seed(seed.trim()).ok()?;
    // An account public key is `A…` — refuse user/server/operator keys as issuer.
    kp.public_key().starts_with('A').then_some(kp)
}

/// Fields the responder needs out of a `$SYS.REQ.USER.AUTH` request.
#[derive(Debug, Clone, PartialEq)]
pub struct AuthRequest {
    /// The ephemeral user public NKey (`U…`) the server minted for this connection.
    pub user_nkey: String,
    /// The requesting server's id (`N…`) — the response `aud`.
    pub server_id: String,
    /// The CONNECT `auth_token` (the realm JWT), if the client presented one.
    pub auth_token: Option<String>,
}

/// Decode the middle (claims) segment of a compact JWT into a JSON value.
fn decode_claims(jwt: &str) -> Option<Value> {
    let mut parts = jwt.split('.');
    let claims_b64 = parts.nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(claims_b64).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Read the request's `user_nkey`, `server_id.id`, and CONNECT `auth_token`. We do
/// NOT re-verify the server's signature here — the transport delivered it on the
/// trusted internal `$SYS` subject; we only read its claims. Returns `None` if the
/// payload is not a well-formed authorization request.
pub fn parse_auth_request(request_jwt: &str) -> Option<AuthRequest> {
    let claims = decode_claims(request_jwt)?;
    let nats = claims.get("nats")?;
    let user_nkey = nats.get("user_nkey")?.as_str()?.to_string();
    let server_id = nats
        .get("server_id")
        .and_then(|s| s.get("id"))
        .and_then(|id| id.as_str())
        .unwrap_or("")
        .to_string();
    let auth_token = nats
        .get("connect_opts")
        .and_then(|c| c.get("auth_token"))
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_string());
    Some(AuthRequest {
        user_nkey,
        server_id,
        auth_token,
    })
}

/// The NATS jti convention: base32(sha256(claims-with-empty-jti)), no padding. Not
/// validated by the broker for acceptance, but computed to match the NATS format.
fn nats_jti(claims: &Value) -> String {
    let mut c = claims.clone();
    if let Some(obj) = c.as_object_mut() {
        obj.insert("jti".to_string(), json!(""));
    }
    // serde_json (default) serialises object keys sorted — canonical, like Go's marshal.
    let ser = serde_json::to_vec(&c).unwrap_or_default();
    let hash = Sha256::digest(&ser);
    data_encoding::BASE32_NOPAD.encode(&hash)
}

/// Encode a NATS v2 claims object into a compact `ed25519-nkey` JWT signed by
/// `signer` (the account key). Sets `jti` per the NATS convention before signing.
fn encode_and_sign(mut claims: Value, signer: &KeyPair) -> Result<String, String> {
    let jti = nats_jti(&claims);
    if let Some(obj) = claims.as_object_mut() {
        obj.insert("jti".to_string(), json!(jti));
    }
    let header = URL_SAFE_NO_PAD.encode(br#"{"typ":"JWT","alg":"ed25519-nkey"}"#);
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).map_err(|e| e.to_string())?);
    let signing_input = format!("{header}.{payload}");
    let sig = signer
        .sign(signing_input.as_bytes())
        .map_err(|e| e.to_string())?;
    let sig_b64 = URL_SAFE_NO_PAD.encode(sig);
    Ok(format!("{signing_input}.{sig_b64}"))
}

/// Mint a signed NATS user-JWT for `user_nkey`, issued by `account`, carrying the
/// governance-derived `perms` and the derived participant `name` (informational —
/// the authoritative identity binding to `ckp.requester` is subject-scoped, task #20).
///
/// `exp` bounds the admission: for a verified connection it is the OIDC token's own
/// expiry, inherited so the broker terminates the connection when the credential that
/// earned it expires. `None` (anonymous) mints without exp — no credential to outlive.
pub fn build_user_jwt(
    user_nkey: &str,
    name: &str,
    perms: &UserPermissions,
    account: &KeyPair,
    iat: i64,
    exp: Option<i64>,
) -> Result<String, String> {
    let pub_perm = if perms.pub_allow.is_empty() {
        json!({ "deny": [">"] })
    } else {
        json!({ "allow": perms.pub_allow })
    };
    let mut claims = json!({
        "iat": iat,
        "iss": account.public_key(),
        "sub": user_nkey,
        // `aud` = the account the admitted user is placed in. Server-config mode
        // REQUIRES it ("account missing" otherwise); with no named accounts the
        // target is the global account `$G` (nats:2.12, callout e2e).
        "aud": "$G",
        "name": name,
        // No `issuer_account`: that claim is operator-mode delegation only — in
        // server-config mode nats:2.x REJECTS it ("attempted to use issuer_account");
        // the account binding is this JWT's signature by the configured issuer.
        "nats": {
            "pub": pub_perm,
            "sub": { "allow": perms.sub_allow },
            "subs": -1,
            "data": -1,
            "payload": -1,
            "type": "user",
            "version": 2
        }
    });
    if let Some(exp) = exp {
        if let Some(obj) = claims.as_object_mut() {
            obj.insert("exp".to_string(), json!(exp));
        }
    }
    encode_and_sign(claims, account)
}

/// Wrap a minted user-JWT (Ok) or an error reason (Err) into a signed
/// AuthorizationResponse, addressed to the requesting `server_id`.
pub fn build_response(
    user_nkey: &str,
    server_id: &str,
    account: &KeyPair,
    result: Result<String, String>,
    iat: i64,
) -> Result<String, String> {
    let nats = match result {
        Ok(user_jwt) => json!({ "jwt": user_jwt, "type": "authorization_response", "version": 2 }),
        Err(reason) => json!({ "error": reason, "type": "authorization_response", "version": 2 }),
    };
    let claims = json!({
        "iat": iat,
        "iss": account.public_key(),
        "sub": user_nkey,
        "aud": server_id,
        "nats": nats
    });
    encode_and_sign(claims, account)
}

/// Full responder pipeline: a `$SYS.REQ.USER.AUTH` request JWT + the realm verifier
/// config + the account signing key + the current time → a signed
/// AuthorizationResponse JWT to publish on the request's reply subject.
///
/// A malformed request yields an error response; a valid request always yields a
/// response (verified ⇒ dispatch perms, otherwise anonymous subscribe-only) — the
/// broker never admits a connection this responder didn't shape.
pub fn handle_request(
    request_jwt: &str,
    cfg: Option<&AuthConfig>,
    account: &KeyPair,
    now_unix: i64,
    admit_anonymous: bool,
    kernels: &[String],
) -> String {
    let req = match parse_auth_request(request_jwt) {
        Some(r) => r,
        None => {
            // Can't even address a response without the user_nkey; emit a
            // best-effort error keyed to an empty subject (broker will reject).
            return build_response("", "", account, Err("malformed request".into()), now_unix)
                .unwrap_or_default();
        }
    };
    let admission = callout_identity(req.auth_token.as_deref(), cfg, now_unix);

    // Every authorization decision is logged. Before this, the responder logged once
    // at startup and never again, so an operator could not distinguish "verified and
    // admitted" from "forged, dropped to anonymous, admitted" — the two look identical
    // from outside, and that ambiguity is what made this defect expensive to trace.
    // The token itself is NEVER logged; only the outcome and whether one was presented.
    let presented = req.auth_token.is_some();
    match &admission {
        Admission::Verified { sub, .. } => {
            eprintln!("pgck auth-callout: ADMIT verified sub={sub} (token presented: {presented})")
        }
        Admission::Anonymous if !admit_anonymous => {
            if cfg.is_none() {
                // The worst reachable state, named as loudly as a log can: strict
                // admittance with NO verifier means nobody can EVER verify, so every
                // connection — every user, every bot, every kernel client — is
                // refused. Anonymous-but-alive beats deny-all; an operator seeing
                // this either restores the JWKS delivery or lifts strict mode.
                eprintln!(
                    "pgck auth-callout: REFUSE unverified (token presented: {presented}); \
                     pgck.admit_anonymous=false AND NO JWKS is loaded — no connection can \
                     verify, so EVERY connection is being refused. Identity delivery is \
                     broken or unconfigured: restore pgck.oidc_jwks (the document, not a \
                     URL) or set pgck.admit_anonymous=on to restore the anonymous tier."
                );
            } else {
                eprintln!(
                    "pgck auth-callout: REFUSE unverified (token presented: {presented}); \
                     pgck.admit_anonymous=false"
                );
            }
        }
        Admission::Anonymous => eprintln!(
            "pgck auth-callout: ADMIT anonymous (token presented: {presented}); \
             subscribe-only, no publish"
        ),
    }

    // Fail-closed option. The default preserves the documented fail-open-to-anonymous
    // tier, because flipping it silently would disconnect every current consumer. An
    // operator who wants unverified connections refused outright sets
    // pgck.admit_anonymous=false and gets a refusal instead of a downgrade.
    if !admit_anonymous && matches!(admission, Admission::Anonymous) {
        return build_response(
            &req.user_nkey,
            &req.server_id,
            account,
            Err("unverified connection refused (pgck.admit_anonymous=false)".into()),
            now_unix,
        )
        .unwrap_or_default();
    }

    let perms = permissions_for(&admission, kernels);
    let name = match &admission {
        Admission::Verified { sub, .. } => format!("urn:ckp:participant:{sub}"),
        Admission::Anonymous => "urn:ckp:participant:anon".to_string(),
    };
    // Admission is bounded by the credential that earned it (IDENTITY-PATH §5.3): a
    // verified connection's user-JWT inherits the token's exp, so the broker itself
    // terminates the connection when the credential expires — a client that never
    // refreshes cannot keep its grants on socket lifetime alone. Anonymous carries no
    // exp: there is no credential to outlive, and the tier holds no publish grants.
    let exp = match &admission {
        Admission::Verified { exp, .. } => Some(*exp),
        Admission::Anonymous => None,
    };
    let user_jwt = build_user_jwt(&req.user_nkey, &name, &perms, account, now_unix, exp);
    build_response(&req.user_nkey, &req.server_id, account, user_jwt, now_unix).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The default single-kernel set, as `pgck.kernels` defaults it. 0.4.78:
    /// the canonical spelling — these tests asserted grants on `pgCK`, the very
    /// segment the substrate refuses, so the unit suite agreed with the defect.
    fn kv() -> Vec<String> {
        vec!["pgck".to_string()]
    }

    // Fail-closed admittance: with admit_anonymous=false an unverified connection is
    // REFUSED, not downgraded. Guards the highest-severity finding of the v3.11 wave —
    // "not-a-jwt-at-all gets in" — and pins that the default still admits.
    #[test]
    fn unverified_is_refused_when_admit_anonymous_is_false() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", Some("not-a-jwt-at-all"));
        let strict = handle_request(&req, None, &account, 1_800_000_000, false, &kv());
        let lenient = handle_request(&req, None, &account, 1_800_000_000, true, &kv());
        // the lenient path mints a user-JWT; the strict path must not
        let lclaims = decode_claims(&lenient).unwrap();
        assert!(lclaims["nats"]["jwt"].is_string(), "lenient admits");
        let sclaims = decode_claims(&strict).unwrap();
        assert!(
            sclaims["nats"]["jwt"].as_str().unwrap_or("").is_empty(),
            "strict must NOT mint a user-JWT for an unverified connection"
        );
        assert_ne!(
            strict, lenient,
            "refusal must differ from admission — if these match, the flag does nothing"
        );
        assert!(
            !strict.is_empty(),
            "a refusal must still be a signed response"
        );
    }

    // A verified admission → dispatch (publish) + read (subscribe) perms, with the
    // publish grant scoped to the connection's OWN identity segment (hop 4:
    // subject-scoping is what makes the F1-inbound `<sub>` broker-enforced).
    #[test]
    fn verified_pub_grant_is_scoped_to_the_connections_own_identity() {
        let sub = "some-verified-sub"; // synthetic — never a captured identity
        let p = permissions_for(
            &Admission::Verified {
                sub: sub.into(),
                exp: 2_000_000_000,
            },
            &kv(),
        );
        assert_eq!(
            p.pub_allow,
            vec![format!("input.kernel.pgCK.id.{sub}.action.>")]
        );
        assert!(p.sub_allow.iter().any(|s| s == &event_subject("pgck")));
        assert!(p.sub_allow.iter().any(|s| s == &result_subject("pgck")));
    }

    // pgCK#30: the grant is DERIVED from the kernel set — a non-pgCK deployment
    // gets grants on ITS OWN kernel, never a hardcoded `pgCK`. This is the exact
    // defect the ticket names: a `demo`/`Dictionary` consumer was granted nothing.
    #[test]
    fn grant_is_derived_per_kernel_not_a_pgck_literal() {
        let sub = "u-1";
        let kernels = vec!["demo".to_string(), "Dictionary".to_string()];
        let p = permissions_for(
            &Admission::Verified {
                sub: sub.into(),
                exp: 2_000_000_000,
            },
            &kernels,
        );
        // publish: one identity-scoped input subject PER kernel, none literal-pgCK
        assert_eq!(
            p.pub_allow,
            vec![
                format!("input.kernel.demo.id.{sub}.action.>"),
                format!("input.kernel.Dictionary.id.{sub}.action.>"),
            ]
        );
        assert!(
            !p.pub_allow.iter().any(|s| s.contains(".pgCK.")),
            "a demo/Dictionary deployment must not be granted pgCK subjects"
        );
        // read: event+result per kernel, plus the one kernel-independent inbox
        assert!(p.sub_allow.contains(&event_subject("demo")));
        assert!(p.sub_allow.contains(&result_subject("Dictionary")));
        assert!(p.sub_allow.contains(&INBOX_SUBJECT.to_string()));
        assert_eq!(
            p.sub_allow.iter().filter(|s| *s == INBOX_SUBJECT).count(),
            1,
            "the inbox is granted once regardless of kernel count"
        );
    }

    // Anonymous over multiple kernels: subscribe on each event stream, no publish.
    #[test]
    fn anonymous_reads_every_configured_kernel_event_stream() {
        let kernels = vec!["demo".to_string(), "Dictionary".to_string()];
        let p = permissions_for(&Admission::Anonymous, &kernels);
        assert!(p.pub_allow.is_empty());
        assert_eq!(
            p.sub_allow,
            vec![event_subject("demo"), event_subject("Dictionary")]
        );
    }

    // Fail-closed floor: an empty kernel set mints NO kernel-scoped grant, rather
    // than silently falling back to a `pgCK` literal.
    #[test]
    fn empty_kernel_set_grants_nothing_kernel_scoped() {
        let p = permissions_for(
            &Admission::Verified {
                sub: "u".into(),
                exp: 2_000_000_000,
            },
            &[],
        );
        assert!(p.pub_allow.is_empty());
        // only the kernel-independent inbox remains for a verified connection
        assert_eq!(p.sub_allow, vec![INBOX_SUBJECT.to_string()]);
    }

    // The GUC-delivered account seed round-trips to the same signing identity;
    // conf-file whitespace is tolerated.
    #[test]
    fn parse_account_seed_accepts_an_account_seed() {
        let kp = KeyPair::new_account();
        let seed = kp.seed().expect("seed");
        let parsed = parse_account_seed(&format!("  {seed}\n")).expect("parses trimmed");
        assert_eq!(parsed.public_key(), kp.public_key());
    }

    // Only an ACCOUNT key may issue: a user seed or garbage never becomes the issuer.
    #[test]
    fn parse_account_seed_rejects_user_seeds_and_garbage() {
        let user_seed = KeyPair::new_user().seed().expect("seed");
        assert!(parse_account_seed(&user_seed).is_none());
        assert!(parse_account_seed("not-a-seed").is_none());
        assert!(parse_account_seed("").is_none());
    }

    // The sub is embedded as ONE subject token: NATS-reserved bytes sanitize to '-'
    // so a hostile sub can't widen its own grant (`.`/`*`/`>` injection).
    #[test]
    fn subject_token_neutralises_nats_reserved_bytes() {
        assert_eq!(subject_token("a.b c*d>e/f"), "a-b-c-d-e-f");
        assert_eq!(subject_token(""), "-");
        // the allowed charset ([A-Za-z0-9_-], the shape of a realm uuid sub)
        // passes through unchanged
        assert_eq!(subject_token("abc-123_XYZ"), "abc-123_XYZ");
    }

    // An anonymous admission → subscribe-only; NO publish.
    #[test]
    fn anonymous_is_subscribe_only() {
        let p = permissions_for(&Admission::Anonymous, &kv());
        assert!(p.pub_allow.is_empty(), "anonymous must not publish");
        assert!(p.sub_allow.iter().any(|s| s == &event_subject("pgck")));
    }

    fn fake_request_jwt(user_nkey: &str, server_id: &str, auth_token: Option<&str>) -> String {
        let connect_opts = match auth_token {
            Some(t) => json!({ "auth_token": t }),
            None => json!({}),
        };
        let claims = json!({
            "iat": 1_700_000_000,
            "aud": "nats-authorization-request",
            "nats": {
                "server_id": { "id": server_id, "name": "pgck-local" },
                "user_nkey": user_nkey,
                "connect_opts": connect_opts,
                "type": "authorization_request",
                "version": 2
            }
        });
        let header = URL_SAFE_NO_PAD.encode(br#"{"typ":"JWT","alg":"ed25519-nkey"}"#);
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        format!("{header}.{payload}.sig") // request sig is not re-verified here
    }

    #[test]
    fn parses_user_nkey_server_and_token() {
        let jwt = fake_request_jwt("UAAA", "NBBB", Some("the.keycloak.jwt"));
        let req = parse_auth_request(&jwt).expect("parses");
        assert_eq!(req.user_nkey, "UAAA");
        assert_eq!(req.server_id, "NBBB");
        assert_eq!(req.auth_token.as_deref(), Some("the.keycloak.jwt"));
    }

    #[test]
    fn absent_token_parses_as_none() {
        let jwt = fake_request_jwt("UAAA", "NBBB", None);
        let req = parse_auth_request(&jwt).expect("parses");
        assert_eq!(req.auth_token, None);
    }

    #[test]
    fn malformed_request_is_none() {
        assert!(parse_auth_request("not-a-jwt").is_none());
    }

    // The minted user-JWT is a well-formed compact JWT whose signature verifies
    // against the account key, and whose claims carry the perms + user_nkey subject.
    #[test]
    fn user_jwt_is_signed_by_account_and_well_formed() {
        let account = KeyPair::new_account();
        let sub = "some-verified-sub"; // synthetic — never a real account name
        let perms = permissions_for(
            &Admission::Verified {
                sub: sub.into(),
                exp: 2_000_000_000,
            },
            &kv(),
        );
        let jwt = build_user_jwt(
            "UXYZ",
            &format!("urn:ckp:participant:{sub}"),
            &perms,
            &account,
            1_700_000_000,
        )
        .expect("mint");
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "compact JWT has 3 segments");
        // signature verifies with the account public key
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert!(account.verify(signing_input.as_bytes(), &sig).is_ok());
        // claims: subject = user_nkey, type = user, dispatch allowed on the
        // connection's own identity-scoped subject only (hop-4 subject-scoping)
        let claims = decode_claims(&jwt).unwrap();
        assert_eq!(claims["sub"], "UXYZ");
        assert_eq!(claims["nats"]["type"], "user");
        assert_eq!(
            claims["nats"]["pub"]["allow"][0],
            format!("input.kernel.pgCK.id.{sub}.action.>")
        );
    }

    // Anonymous user-JWT denies all publish.
    #[test]
    fn anonymous_user_jwt_denies_publish() {
        let account = KeyPair::new_account();
        let perms = permissions_for(&Admission::Anonymous, &kv());
        let jwt = build_user_jwt(
            "UXYZ",
            "urn:ckp:participant:anon",
            &perms,
            &account,
            1,
            None,
        )
        .expect("mint");
        let claims = decode_claims(&jwt).unwrap();
        assert_eq!(claims["nats"]["pub"]["deny"][0], ">");
    }

    // End-to-end (no realm config) → anonymous response: valid, signed, addressed,
    // carrying an anonymous user-JWT (no dispatch).
    #[test]
    fn handle_request_without_config_admits_anonymous() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", Some("unverifiable.token"));
        let resp = handle_request(&req, None, &account, 1_700_000_000, true, &kv());
        let parts: Vec<&str> = resp.split('.').collect();
        assert_eq!(parts.len(), 3);
        let claims = decode_claims(&resp).unwrap();
        assert_eq!(claims["sub"], "UCONN");
        assert_eq!(claims["aud"], "NSERVER");
        // the embedded user-JWT is anonymous (deny publish)
        let user_jwt = claims["nats"]["jwt"].as_str().unwrap();
        let uclaims = decode_claims(user_jwt).unwrap();
        assert_eq!(uclaims["nats"]["pub"]["deny"][0], ">");
    }

    // Server-config mode places the admitted user by the user JWT's `aud` — an
    // empty audience is rejected (`No valid account "" for auth callout response
    // on account "$G": account missing`, observed on nats:2.12, callout e2e).
    // Without named accounts the target is the global account `$G`.
    #[test]
    fn user_jwt_audience_is_the_global_account() {
        let account = KeyPair::new_account();
        let perms = permissions_for(&Admission::Anonymous, &kv());
        let jwt = build_user_jwt(
            "UXYZ",
            "urn:ckp:participant:anon",
            &perms,
            &account,
            1,
            None,
        )
        .expect("mint");
        let claims = decode_claims(&jwt).unwrap();
        assert_eq!(claims["aud"], "$G");
    }

    // Server-config (non-operator) callout: NATS rejects a user JWT carrying
    // `issuer_account` with `non operator mode account "$G": attempted to use
    // issuer_account` (observed on nats:2.12, callout e2e). The account binding
    // is the issuer SIGNATURE itself — the claim must be absent.
    #[test]
    fn user_jwt_carries_no_issuer_account_in_config_mode() {
        let account = KeyPair::new_account();
        let perms = permissions_for(&Admission::Anonymous, &kv());
        let jwt = build_user_jwt(
            "UXYZ",
            "urn:ckp:participant:anon",
            &perms,
            &account,
            1,
            None,
        )
        .expect("mint");
        let claims = decode_claims(&jwt).unwrap();
        assert!(
            claims["nats"].get("issuer_account").is_none(),
            "issuer_account is operator-mode-only; config mode must omit it"
        );
    }

    // The response is signed by the account (broker-verifiable).
    #[test]
    fn response_is_signed_by_account() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", None);
        let resp = handle_request(&req, None, &account, 1, true, &kv());
        let parts: Vec<&str> = resp.split('.').collect();
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert!(account.verify(signing_input.as_bytes(), &sig).is_ok());
    }

    // Admission is bounded by the credential that earned it (IDENTITY-PATH §5.3):
    // the minted user-JWT INHERITS the verified token's exp, so the broker itself
    // terminates a connection whose credential expired — a client that never
    // refreshes cannot keep its grants on socket lifetime alone. Full round-trip
    // through handle_request with a locally-played realm, so the assertion covers
    // the wiring, not just the mint helper.
    #[test]
    fn verified_user_jwt_inherits_the_tokens_exp() {
        let realm = fresh_ed25519();
        let account = KeyPair::new_account();
        let kid = "exp-test";
        let issuer = "https://pgck-exp.invalid/realms/t"; // .invalid — never routable
        let audience = "account";
        let x = URL_SAFE_NO_PAD.encode(realm.verifying_key().to_bytes());
        let jwks = json!({"keys":[{"kty":"OKP","crv":"Ed25519","kid":kid,"x":x}]}).to_string();
        let cfg = AuthConfig::from_parts(&jwks, issuer, audience).expect("jwks parses");

        let now = 1_700_000_000_i64;
        let token_exp = now + 300; // a short-lived credential
        let claims = json!({"iss":issuer,"aud":audience,"sub":"exp-sub","iat":now,"exp":token_exp});
        let token = sign_realm_jwt(&claims, kid, &realm);

        let req = fake_request_jwt("UCONN", "NSERVER", Some(&token));
        let resp = handle_request(&req, Some(&cfg), &account, now, true, &kv());
        let rclaims = decode_claims(&resp).unwrap();
        let user_jwt = rclaims["nats"]["jwt"].as_str().expect("embedded user JWT");
        let uclaims = decode_claims(user_jwt).unwrap();
        assert_eq!(
            uclaims["exp"].as_i64(),
            Some(token_exp),
            "minted user-JWT must inherit the verified token's exp"
        );
    }

    // The anonymous tier holds no credential to outlive (and no publish grants),
    // so its user-JWT carries NO exp — unchanged from the pre-fix behaviour.
    #[test]
    fn anonymous_user_jwt_carries_no_exp() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", None);
        let resp = handle_request(&req, None, &account, 1_700_000_000, true, &kv());
        let rclaims = decode_claims(&resp).unwrap();
        let user_jwt = rclaims["nats"]["jwt"].as_str().expect("embedded user JWT");
        let uclaims = decode_claims(user_jwt).unwrap();
        assert!(
            uclaims.get("exp").is_none(),
            "anonymous admission has no credential to inherit an exp from"
        );
    }

    // ── e2e fixture emitter (cycle-6 wire proof; scripts/dev-callout-e2e.sh) ──
    // Env-driven and #[ignore]d like the real-token verifier test: runs only when
    // the e2e script sets PGCK_E2E_DIR. It plays the realm locally — a fresh
    // Ed25519 signing key becomes the JWKS, a fresh account nkey the callout
    // issuer. Everything is generated per run and synthetic; nothing captured,
    // nothing reusable outside the scratch dir.

    /// A fresh Ed25519 signing key without a rand dependency: nkeys (Ed25519 too)
    /// mints the entropy; its seed payload bytes seed the dalek key.
    fn fresh_ed25519() -> ed25519_dalek::SigningKey {
        let seed_b32 = KeyPair::new_user().seed().expect("seed");
        let raw = data_encoding::BASE32_NOPAD
            .decode(seed_b32.as_bytes())
            .expect("nkey seed is unpadded base32");
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&raw[2..34]); // [2-byte prefix][32-byte seed][2-byte crc]
        ed25519_dalek::SigningKey::from_bytes(&sk)
    }

    /// Compact EdDSA JWT signed by `key` — the shape the configured realm issues.
    fn sign_realm_jwt(claims: &Value, kid: &str, key: &ed25519_dalek::SigningKey) -> String {
        use ed25519_dalek::Signer;
        let header =
            URL_SAFE_NO_PAD.encode(format!(r#"{{"alg":"EdDSA","typ":"JWT","kid":"{kid}"}}"#));
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).expect("claims"));
        let input = format!("{header}.{payload}");
        let sig = key.sign(input.as_bytes());
        format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()))
    }

    #[test]
    #[ignore] // e2e-only: needs PGCK_E2E_DIR; driven by scripts/dev-callout-e2e.sh
    fn e2e_emit_callout_fixtures() {
        let dir = std::env::var("PGCK_E2E_DIR").expect("set PGCK_E2E_DIR to a scratch dir");
        let dir = std::path::Path::new(&dir);

        let sub = "e2e-verified-sub"; // synthetic
        let issuer = "https://pgck-e2e.invalid/realms/e2e"; // .invalid — never routable
        let audience = "account"; // the resource aud shape (SPEC.SECURITY §3)
        let kid = "e2e";

        let realm = fresh_ed25519();
        let stranger = fresh_ed25519(); // forges with a key the realm never published
        let account = KeyPair::new_account();

        let x = URL_SAFE_NO_PAD.encode(realm.verifying_key().to_bytes());
        let jwks = json!({"keys":[{"kty":"OKP","crv":"Ed25519","kid":kid,"x":x}]}).to_string();

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_secs() as i64;
        let claims = json!({"iss":issuer,"aud":audience,"sub":sub,"iat":now,"exp":now+3600});
        let valid = sign_realm_jwt(&claims, kid, &realm);
        let forged = sign_realm_jwt(&claims, kid, &stranger);

        // Sanity: the emitted fixtures round-trip through the SHIPPED verifier —
        // if this fails, the e2e would fail for fixture reasons, not wire reasons.
        let cfg = AuthConfig::from_parts(&jwks, issuer, audience).expect("jwks parses");
        assert!(matches!(
            callout_identity(Some(&valid), Some(&cfg), now),
            Admission::Verified { .. }
        ));
        assert!(matches!(
            callout_identity(Some(&forged), Some(&cfg), now),
            Admission::Anonymous
        ));

        std::fs::write(dir.join("token.valid"), &valid).expect("write token.valid");
        std::fs::write(dir.join("token.forged"), &forged).expect("write token.forged");
        let env = format!(
            "PGCK_E2E_SUB='{sub}'\n\
             PGCK_E2E_ISSUER='{issuer}'\n\
             PGCK_E2E_AUDIENCE='{audience}'\n\
             PGCK_CALLOUT_ISSUER='{}'\n\
             PGCK_E2E_ACCOUNT_SEED='{}'\n\
             PGCK_E2E_JWKS='{jwks}'\n",
            account.public_key(),
            account.seed().expect("account seed"),
        );
        std::fs::write(dir.join("e2e.env"), env).expect("write e2e.env");
        eprintln!("pgck e2e: fixtures emitted to {}", dir.display());
    }
}
