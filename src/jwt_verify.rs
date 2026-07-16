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
