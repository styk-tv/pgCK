//! In-memory EdDSA (Ed25519) JWT verifier for the pgCK auth-callout (F-A / SPEC.OAUTH2 §3.3).
//!
//! Pure, offline, no network, no NATS, no pg: given an in-memory Ed25519 public key — loaded once
//! from the configured realm's JWKS at startup — and a compact JWT, verify the signature *and* the
//! `iss`/`aud`/`exp`/`nbf` claims, and return the participant identity (`sub`).
//!
//! This is the "un-forgeable unless it comes from the configured realm" heart: a token signed by any
//! other key fails the local Ed25519 check; a tampered token fails it; a token for another realm or
//! client fails the claim checks. The verified `sub` becomes the `ckp.requester` the seal path
//! persists (F-A substrate half, v0.4.22 / s58).
//!
//! The clock is INJECTED (`Expected.now_unix`) so expiry is deterministic and unit-testable — there
//! is no ambient time here.

#![allow(dead_code)] // wired into the auth-callout responder in a later F1 increment.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use std::collections::HashMap;

/// A verified participant identity, derived from a JWT that passed BOTH signature and claim checks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    pub sub: String,
    pub preferred_username: Option<String>,
}

/// Why a token was rejected. Every variant means: do NOT admit this identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerifyError {
    Malformed,      // not three base64url segments / undecodable / bad JSON
    UnsupportedAlg, // header `alg` is not EdDSA
    BadSignature,   // Ed25519 verification failed (wrong key / tampered content)
    Expired,        // `exp` <= now (or `exp` absent — never accept unbounded)
    NotYetValid,    // `nbf` > now
    WrongIssuer,    // `iss` != expected realm issuer
    WrongAudience,  // `aud` does not include the expected client
    MissingSub,     // no `sub` claim
}

/// What the verifier requires the token to assert. `now_unix` is injected (no ambient clock).
pub struct Expected<'a> {
    pub issuer: &'a str,
    pub audience: &'a str,
    pub now_unix: i64,
    pub leeway_secs: i64,
}

/// Verify a compact EdDSA JWT against an in-memory Ed25519 public key + the expected claims.
/// Returns the identity only if the signature is authentic AND every claim check passes.
pub fn verify_eddsa(
    token: &str,
    pubkey: &VerifyingKey,
    expected: &Expected,
) -> Result<VerifiedIdentity, VerifyError> {
    // 1. Split the compact JWS into exactly three base64url segments.
    let mut parts = token.split('.');
    let h_b64 = parts.next().ok_or(VerifyError::Malformed)?;
    let p_b64 = parts.next().ok_or(VerifyError::Malformed)?;
    let s_b64 = parts.next().ok_or(VerifyError::Malformed)?;
    if parts.next().is_some() {
        return Err(VerifyError::Malformed);
    }

    // 2. Header: the algorithm MUST be EdDSA (never trust a caller-chosen alg / "none").
    let header: serde_json::Value =
        serde_json::from_slice(&b64(h_b64)?).map_err(|_| VerifyError::Malformed)?;
    if header.get("alg").and_then(|v| v.as_str()) != Some("EdDSA") {
        return Err(VerifyError::UnsupportedAlg);
    }

    // 3. Verify the Ed25519 signature over the ASCII "header.payload" — BEFORE trusting any claim.
    //    A wrong key or any tampering of header/payload fails here.
    let sig = Signature::from_slice(&b64(s_b64)?).map_err(|_| VerifyError::BadSignature)?;
    let signing_input = format!("{h_b64}.{p_b64}");
    pubkey
        .verify(signing_input.as_bytes(), &sig)
        .map_err(|_| VerifyError::BadSignature)?;

    // 4. Claims — only now that the payload is proven authentic.
    let claims: serde_json::Value =
        serde_json::from_slice(&b64(p_b64)?).map_err(|_| VerifyError::Malformed)?;

    if claims.get("iss").and_then(|v| v.as_str()) != Some(expected.issuer) {
        return Err(VerifyError::WrongIssuer);
    }
    if !aud_contains(claims.get("aud"), expected.audience) {
        return Err(VerifyError::WrongAudience);
    }
    // `exp` is mandatory — an absent exp is treated as expired (never admit an unbounded token).
    match claims.get("exp").and_then(|v| v.as_i64()) {
        Some(exp) if exp + expected.leeway_secs > expected.now_unix => {}
        _ => return Err(VerifyError::Expired),
    }
    if let Some(nbf) = claims.get("nbf").and_then(|v| v.as_i64()) {
        if nbf - expected.leeway_secs > expected.now_unix {
            return Err(VerifyError::NotYetValid);
        }
    }

    let sub = claims
        .get("sub")
        .and_then(|v| v.as_str())
        .ok_or(VerifyError::MissingSub)?
        .to_string();
    let preferred_username = claims
        .get("preferred_username")
        .and_then(|v| v.as_str())
        .map(str::to_string);

    Ok(VerifiedIdentity {
        sub,
        preferred_username,
    })
}

fn b64(s: &str) -> Result<Vec<u8>, VerifyError> {
    URL_SAFE_NO_PAD
        .decode(s)
        .map_err(|_| VerifyError::Malformed)
}

/// JWT `aud` may be a single string or an array of strings; accept either form.
fn aud_contains(aud: Option<&serde_json::Value>, want: &str) -> bool {
    match aud {
        Some(serde_json::Value::String(s)) => s == want,
        Some(serde_json::Value::Array(a)) => a.iter().any(|v| v.as_str() == Some(want)),
        _ => false,
    }
}

/// The realm's signing keys, loaded once from the JWKS and held in memory, indexed by `kid`.
/// Only Ed25519 (`kty:OKP, crv:Ed25519`) keys are kept — the auth-callout only accepts EdDSA.
pub struct Jwks {
    keys: HashMap<String, VerifyingKey>,
}

impl Jwks {
    /// Parse a JWKS document (`{"keys":[…]}`) into the in-memory Ed25519 key set.
    /// Non-Ed25519 entries (RSA/EC) and malformed keys are skipped, not fatal — a realm may
    /// publish multiple key types. Errors only if no usable Ed25519 key is present.
    pub fn parse(jwks_json: &str) -> Result<Jwks, VerifyError> {
        let doc: serde_json::Value =
            serde_json::from_str(jwks_json).map_err(|_| VerifyError::Malformed)?;
        let arr = doc
            .get("keys")
            .and_then(|v| v.as_array())
            .ok_or(VerifyError::Malformed)?;
        let mut keys = HashMap::new();
        for jwk in arr {
            if jwk.get("kty").and_then(|v| v.as_str()) != Some("OKP") {
                continue;
            }
            if jwk.get("crv").and_then(|v| v.as_str()) != Some("Ed25519") {
                continue;
            }
            let (Some(kid), Some(x)) = (
                jwk.get("kid").and_then(|v| v.as_str()),
                jwk.get("x").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            let Ok(bytes) = b64(x) else { continue };
            let Ok(arr32) = <[u8; 32]>::try_from(bytes) else {
                continue;
            };
            if let Ok(vk) = VerifyingKey::from_bytes(&arr32) {
                keys.insert(kid.to_string(), vk);
            }
        }
        if keys.is_empty() {
            return Err(VerifyError::Malformed);
        }
        Ok(Jwks { keys })
    }

    pub fn get(&self, kid: &str) -> Option<&VerifyingKey> {
        self.keys.get(kid)
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

/// Verify a JWT by selecting the signing key from the loaded JWKS via the token header's `kid`,
/// then running the full [`verify_eddsa`] signature + claim checks. An unknown `kid` cannot be
/// verified → rejected (a later increment refetches the JWKS once on a `kid` miss — SPEC.OAUTH2 §3.3).
pub fn verify_jwt(
    token: &str,
    jwks: &Jwks,
    expected: &Expected,
) -> Result<VerifiedIdentity, VerifyError> {
    let h_b64 = token.split('.').next().ok_or(VerifyError::Malformed)?;
    let header: serde_json::Value =
        serde_json::from_slice(&b64(h_b64)?).map_err(|_| VerifyError::Malformed)?;
    let kid = header
        .get("kid")
        .and_then(|v| v.as_str())
        .ok_or(VerifyError::Malformed)?;
    // Unknown kid: no key to verify against → reject (a later increment refetches the JWKS once).
    let key = jwks.get(kid).ok_or(VerifyError::BadSignature)?;
    verify_eddsa(token, key, expected)
}

/// The auth-callout's in-memory verifier state, built ONCE at startup from **env/GUC-delivered
/// config** — the realm JWKS (public key JWK), the expected issuer, and the audience — exactly the
/// way the other Keycloak parameters are configured. **No egress HTTP, no network in the live path.**
/// Rotation is handled by re-delivering the config on the next cold start (SPEC.OAUTH2 §3.3).
pub struct AuthConfig {
    jwks: Jwks,
    issuer: String,
    audience: String,
    leeway_secs: i64,
}

impl AuthConfig {
    /// Build from the config strings the operator delivers (JWKS JSON + issuer + audience).
    pub fn from_parts(
        jwks_json: &str,
        issuer: &str,
        audience: &str,
    ) -> Result<AuthConfig, VerifyError> {
        Ok(AuthConfig {
            jwks: Jwks::parse(jwks_json)?,
            issuer: issuer.to_string(),
            audience: audience.to_string(),
            leeway_secs: 30,
        })
    }

    /// Verify a token against the loaded JWKS + configured claims at time `now_unix`.
    pub fn verify(&self, token: &str, now_unix: i64) -> Result<VerifiedIdentity, VerifyError> {
        verify_jwt(
            token,
            &self.jwks,
            &Expected {
                issuer: &self.issuer,
                audience: &self.audience,
                now_unix,
                leeway_secs: self.leeway_secs,
            },
        )
    }
}

/// The auth-callout's admission decision for a CONNECT.
///
/// **Fail-open-to-anonymous, NEVER fail-open-to-admitted.** An absent/invalid/forged token — or
/// verification not configured — yields `Anonymous` (the caller assigns a server-side nonce). It
/// MUST NEVER admit the *claimed* identity of an unverified token. Only a cryptographically verified
/// token yields `Verified{sub}`, and that `sub` becomes the `ckp.requester` the seal path persists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admission {
    Verified { sub: String },
    Anonymous,
}

/// Decide the admission identity for a CONNECT token — the security core of the auth-callout
/// (F1 piece 3). The NATS wire (subscribe `$SYS.REQ.USER.AUTH`, mint the scoped user-JWT) is built
/// AROUND this decision. `cfg == None` ⇒ OIDC verification is not configured ⇒ anonymous (the broker
/// stays open exactly as today — no breakage when unconfigured).
pub fn callout_identity(token: Option<&str>, cfg: Option<&AuthConfig>, now_unix: i64) -> Admission {
    match (token, cfg) {
        (Some(t), Some(c)) => match c.verify(t, now_unix) {
            Ok(id) => Admission::Verified { sub: id.sub },
            // A present-but-invalid/forged token drops to anonymous — it is NEVER admitted as the
            // identity it claims. This is the un-forgeable property at the admission boundary.
            Err(_) => Admission::Anonymous,
        },
        // No token, or verification not configured → anonymous (broker stays open, unchanged).
        _ => Admission::Anonymous,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    const ISS: &str = "https://id.example/realms/R";
    const AUD: &str = "ck-browser";

    fn key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32])
    }

    fn claims(iss: &str, aud: &str, sub: &str, exp: i64) -> serde_json::Value {
        serde_json::json!({
            "iss": iss, "aud": aud, "sub": sub, "exp": exp, "nbf": 0,
            "preferred_username": "tester"
        })
    }

    /// Mint a compact EdDSA JWT for the given claims, signed by `sk` (the realm key).
    fn mint(sk: &SigningKey, claims: &serde_json::Value) -> String {
        let header = serde_json::json!({ "alg": "EdDSA", "typ": "JWT" });
        let h = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let p = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap());
        let signing_input = format!("{h}.{p}");
        let sig = sk.sign(signing_input.as_bytes());
        let s = URL_SAFE_NO_PAD.encode(sig.to_bytes());
        format!("{h}.{p}.{s}")
    }

    fn expected<'a>(iss: &'a str, aud: &'a str, now: i64) -> Expected<'a> {
        Expected {
            issuer: iss,
            audience: aud,
            now_unix: now,
            leeway_secs: 30,
        }
    }

    /// A JWKS public JWK entry for the given signing key.
    fn jwk(sk: &SigningKey, kid: &str) -> serde_json::Value {
        let x = URL_SAFE_NO_PAD.encode(sk.verifying_key().to_bytes());
        serde_json::json!({ "kty":"OKP","crv":"Ed25519","use":"sig","alg":"EdDSA","kid":kid,"x":x })
    }

    fn jwks_doc(keys: Vec<serde_json::Value>) -> String {
        serde_json::json!({ "keys": keys }).to_string()
    }

    /// Mint a token whose header carries `kid` (the JWKS key-selection case).
    fn mint_kid(sk: &SigningKey, kid: &str, claims: &serde_json::Value) -> String {
        let header = serde_json::json!({ "alg":"EdDSA","typ":"JWT","kid":kid });
        let h = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let p = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap());
        let sig = sk.sign(format!("{h}.{p}").as_bytes());
        let s = URL_SAFE_NO_PAD.encode(sig.to_bytes());
        format!("{h}.{p}.{s}")
    }

    #[test]
    fn parse_jwks_loads_ed25519_keys_by_kid() {
        let sk = key(1);
        let jwks = Jwks::parse(&jwks_doc(vec![jwk(&sk, "k1")])).unwrap();
        assert_eq!(jwks.len(), 1);
        assert!(jwks.get("k1").is_some());
        assert!(jwks.get("nope").is_none());
    }

    #[test]
    fn parse_jwks_skips_non_ed25519_keys() {
        let sk = key(1);
        let rsa = serde_json::json!({ "kty":"RSA","kid":"rsa1","n":"x","e":"AQAB" });
        let jwks = Jwks::parse(&jwks_doc(vec![rsa, jwk(&sk, "ed1")])).unwrap();
        assert_eq!(jwks.len(), 1);
        assert!(jwks.get("ed1").is_some());
        assert!(jwks.get("rsa1").is_none());
    }

    #[test]
    fn verify_jwt_selects_the_key_by_kid() {
        let k1 = key(1);
        let k2 = key(2);
        let jwks = Jwks::parse(&jwks_doc(vec![jwk(&k1, "k1"), jwk(&k2, "k2")])).unwrap();
        let t = mint_kid(&k2, "k2", &claims(ISS, AUD, "alice", 10_000));
        let id = verify_jwt(&t, &jwks, &expected(ISS, AUD, 9_000)).unwrap();
        assert_eq!(id.sub, "alice");
    }

    #[test]
    fn verify_jwt_rejects_a_kid_signed_by_the_wrong_key() {
        // header claims kid=k2 but the token is signed by k1 — verify against k2's key → reject.
        let k1 = key(1);
        let k2 = key(2);
        let jwks = Jwks::parse(&jwks_doc(vec![jwk(&k1, "k1"), jwk(&k2, "k2")])).unwrap();
        let t = mint_kid(&k1, "k2", &claims(ISS, AUD, "mallory", 10_000));
        assert_eq!(
            verify_jwt(&t, &jwks, &expected(ISS, AUD, 9_000)),
            Err(VerifyError::BadSignature)
        );
    }

    #[test]
    fn verify_jwt_rejects_an_unknown_kid() {
        let k1 = key(1);
        let jwks = Jwks::parse(&jwks_doc(vec![jwk(&k1, "k1")])).unwrap();
        let t = mint_kid(&k1, "unknown", &claims(ISS, AUD, "alice", 10_000));
        assert_eq!(
            verify_jwt(&t, &jwks, &expected(ISS, AUD, 9_000)),
            Err(VerifyError::BadSignature)
        );
    }

    #[test]
    fn auth_config_verifies_from_env_delivered_jwks_without_network() {
        let realm = key(1);
        let cfg = AuthConfig::from_parts(&jwks_doc(vec![jwk(&realm, "k1")]), ISS, AUD).unwrap();
        // a valid realm-signed token is admitted
        let ok = mint_kid(&realm, "k1", &claims(ISS, AUD, "alice", 10_000));
        assert_eq!(cfg.verify(&ok, 9_000).unwrap().sub, "alice");
        // a token claiming the realm's kid but signed by a foreign key is rejected
        let foreign = key(9);
        let bad = mint_kid(&foreign, "k1", &claims(ISS, AUD, "mallory", 10_000));
        assert_eq!(cfg.verify(&bad, 9_000), Err(VerifyError::BadSignature));
    }

    #[test]
    fn callout_admits_anonymous_when_no_token() {
        let realm = key(1);
        let cfg = AuthConfig::from_parts(&jwks_doc(vec![jwk(&realm, "k1")]), ISS, AUD).unwrap();
        assert_eq!(
            callout_identity(None, Some(&cfg), 9_000),
            Admission::Anonymous
        );
    }

    #[test]
    fn callout_admits_anonymous_when_verification_not_configured() {
        // even a real token → anonymous when no AuthConfig (verification off ⇒ broker unchanged).
        let realm = key(1);
        let t = mint_kid(&realm, "k1", &claims(ISS, AUD, "alice", 10_000));
        assert_eq!(
            callout_identity(Some(&t), None, 9_000),
            Admission::Anonymous
        );
    }

    #[test]
    fn callout_verifies_a_valid_token_to_its_sub() {
        let realm = key(1);
        let cfg = AuthConfig::from_parts(&jwks_doc(vec![jwk(&realm, "k1")]), ISS, AUD).unwrap();
        let t = mint_kid(&realm, "k1", &claims(ISS, AUD, "alice", 10_000));
        assert_eq!(
            callout_identity(Some(&t), Some(&cfg), 9_000),
            Admission::Verified {
                sub: "alice".into()
            }
        );
    }

    #[test]
    fn callout_drops_a_forged_token_to_anonymous_never_admitting_the_claim() {
        // the crux: a foreign-signed token claiming sub=mallory MUST be Anonymous, never Verified{mallory}.
        let realm = key(1);
        let foreign = key(9);
        let cfg = AuthConfig::from_parts(&jwks_doc(vec![jwk(&realm, "k1")]), ISS, AUD).unwrap();
        let forged = mint_kid(&foreign, "k1", &claims(ISS, AUD, "mallory", 10_000));
        assert_eq!(
            callout_identity(Some(&forged), Some(&cfg), 9_000),
            Admission::Anonymous
        );
    }

    #[test]
    fn accepts_a_valid_token_signed_by_the_realm_key() {
        let sk = key(1);
        let t = mint(&sk, &claims(ISS, AUD, "alice", 10_000));
        let id = verify_eddsa(&t, &sk.verifying_key(), &expected(ISS, AUD, 9_000)).unwrap();
        assert_eq!(id.sub, "alice");
        assert_eq!(id.preferred_username.as_deref(), Some("tester"));
    }

    #[test]
    fn rejects_a_token_signed_by_a_foreign_realm_key() {
        let realm = key(1);
        let foreign = key(2);
        let t = mint(&foreign, &claims(ISS, AUD, "mallory", 10_000));
        assert_eq!(
            verify_eddsa(&t, &realm.verifying_key(), &expected(ISS, AUD, 9_000)),
            Err(VerifyError::BadSignature)
        );
    }

    #[test]
    fn rejects_a_tampered_payload_keeping_the_original_signature() {
        // classic claim-swap: alice's header+signature, bob's payload. The signature covers
        // alice's payload, so verifying over bob's payload MUST fail.
        let sk = key(1);
        let alice = mint(&sk, &claims(ISS, AUD, "alice", 10_000));
        let bob = mint(&sk, &claims(ISS, AUD, "bob", 10_000));
        let a: Vec<&str> = alice.split('.').collect();
        let b: Vec<&str> = bob.split('.').collect();
        let forged = format!("{}.{}.{}", a[0], b[1], a[2]);
        assert_eq!(
            verify_eddsa(&forged, &sk.verifying_key(), &expected(ISS, AUD, 9_000)),
            Err(VerifyError::BadSignature)
        );
    }

    #[test]
    fn rejects_an_expired_token() {
        let sk = key(1);
        let t = mint(&sk, &claims(ISS, AUD, "alice", 1_000));
        assert_eq!(
            verify_eddsa(&t, &sk.verifying_key(), &expected(ISS, AUD, 9_000)),
            Err(VerifyError::Expired)
        );
    }

    #[test]
    fn rejects_a_wrong_issuer() {
        let sk = key(1);
        let t = mint(&sk, &claims("https://evil/realms/X", AUD, "alice", 10_000));
        assert_eq!(
            verify_eddsa(&t, &sk.verifying_key(), &expected(ISS, AUD, 9_000)),
            Err(VerifyError::WrongIssuer)
        );
    }

    #[test]
    fn rejects_a_wrong_audience() {
        let sk = key(1);
        let t = mint(&sk, &claims(ISS, "some-other-client", "alice", 10_000));
        assert_eq!(
            verify_eddsa(&t, &sk.verifying_key(), &expected(ISS, AUD, 9_000)),
            Err(VerifyError::WrongAudience)
        );
    }
}
