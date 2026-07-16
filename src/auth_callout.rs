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
#![allow(dead_code)] // wired under nats-client; the core stays unit-testable regardless.

use crate::jwt_verify::{callout_identity, Admission, AuthConfig};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use nkeys::KeyPair;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// The action subject a verified participant may publish dispatches to, and the
/// event/result subjects any admitted connection may read. Governance-derived
/// (the transport gate mirrors the kernel's own `event.kernel.pgCK.*` surface).
const DISPATCH_SUBJECT: &str = "input.kernel.pgCK.action.>";
const EVENT_SUBJECT: &str = "event.kernel.pgCK.>";
const RESULT_SUBJECT: &str = "result.kernel.pgCK.>";
const INBOX_SUBJECT: &str = "_INBOX.>";

/// NATS subject permissions minted for a connection.
#[derive(Debug, Clone, PartialEq)]
pub struct UserPermissions {
    /// Subjects the connection may publish to. Empty ⇒ deny all publish.
    pub pub_allow: Vec<String>,
    /// Subjects the connection may subscribe to.
    pub sub_allow: Vec<String>,
}

/// Governance-derived admittance permissions (SPEC.OAUTH2 §5 Tier 2):
/// - **Verified** — may DISPATCH (publish `input.kernel.pgCK.action.>`) and read
///   events + results + its own inbox.
/// - **Anonymous** — subscribe-only on the public event stream; NO publish. The
///   kernel still refuses to trust any client-claimed identity, so an anonymous
///   connection can observe but not act.
pub fn permissions_for(admission: &Admission) -> UserPermissions {
    match admission {
        Admission::Verified { .. } => UserPermissions {
            pub_allow: vec![DISPATCH_SUBJECT.to_string()],
            sub_allow: vec![
                EVENT_SUBJECT.to_string(),
                RESULT_SUBJECT.to_string(),
                INBOX_SUBJECT.to_string(),
            ],
        },
        Admission::Anonymous => UserPermissions {
            pub_allow: vec![], // deny all publish
            sub_allow: vec![EVENT_SUBJECT.to_string()],
        },
    }
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
pub fn build_user_jwt(
    user_nkey: &str,
    name: &str,
    perms: &UserPermissions,
    account: &KeyPair,
    iat: i64,
) -> Result<String, String> {
    let pub_perm = if perms.pub_allow.is_empty() {
        json!({ "deny": [">"] })
    } else {
        json!({ "allow": perms.pub_allow })
    };
    let claims = json!({
        "iat": iat,
        "iss": account.public_key(),
        "sub": user_nkey,
        "name": name,
        "nats": {
            "issuer_account": account.public_key(),
            "pub": pub_perm,
            "sub": { "allow": perms.sub_allow },
            "subs": -1,
            "data": -1,
            "payload": -1,
            "type": "user",
            "version": 2
        }
    });
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
    let perms = permissions_for(&admission);
    let name = match &admission {
        Admission::Verified { sub } => format!("urn:ckp:participant:{sub}"),
        Admission::Anonymous => "urn:ckp:participant:anon".to_string(),
    };
    let user_jwt = build_user_jwt(&req.user_nkey, &name, &perms, account, now_unix);
    build_response(&req.user_nkey, &req.server_id, account, user_jwt, now_unix)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    // A verified admission → dispatch (publish) + read (subscribe) perms.
    #[test]
    fn verified_may_dispatch_and_read() {
        let p = permissions_for(&Admission::Verified { sub: "test26".into() });
        assert!(p.pub_allow.iter().any(|s| s == DISPATCH_SUBJECT));
        assert!(p.sub_allow.iter().any(|s| s == EVENT_SUBJECT));
    }

    // An anonymous admission → subscribe-only; NO publish.
    #[test]
    fn anonymous_is_subscribe_only() {
        let p = permissions_for(&Admission::Anonymous);
        assert!(p.pub_allow.is_empty(), "anonymous must not publish");
        assert!(p.sub_allow.iter().any(|s| s == EVENT_SUBJECT));
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
        let perms = permissions_for(&Admission::Verified { sub: "test26".into() });
        let jwt = build_user_jwt("UXYZ", "urn:ckp:participant:test26", &perms, &account, 1_700_000_000)
            .expect("mint");
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "compact JWT has 3 segments");
        // signature verifies with the account public key
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert!(account.verify(signing_input.as_bytes(), &sig).is_ok());
        // claims: subject = user_nkey, type = user, dispatch allowed
        let claims = decode_claims(&jwt).unwrap();
        assert_eq!(claims["sub"], "UXYZ");
        assert_eq!(claims["nats"]["type"], "user");
        assert_eq!(claims["nats"]["pub"]["allow"][0], DISPATCH_SUBJECT);
    }

    // Anonymous user-JWT denies all publish.
    #[test]
    fn anonymous_user_jwt_denies_publish() {
        let account = KeyPair::new_account();
        let perms = permissions_for(&Admission::Anonymous);
        let jwt = build_user_jwt("UXYZ", "urn:ckp:participant:anon", &perms, &account, 1).expect("mint");
        let claims = decode_claims(&jwt).unwrap();
        assert_eq!(claims["nats"]["pub"]["deny"][0], ">");
    }

    // End-to-end (no realm config) → anonymous response: valid, signed, addressed,
    // carrying an anonymous user-JWT (no dispatch).
    #[test]
    fn handle_request_without_config_admits_anonymous() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", Some("unverifiable.token"));
        let resp = handle_request(&req, None, &account, 1_700_000_000);
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

    // The response is signed by the account (broker-verifiable).
    #[test]
    fn response_is_signed_by_account() {
        let account = KeyPair::new_account();
        let req = fake_request_jwt("UCONN", "NSERVER", None);
        let resp = handle_request(&req, None, &account, 1);
        let parts: Vec<&str> = resp.split('.').collect();
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert!(account.verify(signing_input.as_bytes(), &sig).is_ok());
    }
}
