//! pgCK — PostgreSQL Concept Kernel extension.
//!
//! Composition:
//!   * pgRDF (required) holds the ontology + runs SHACL/SPARQL.
//!   * pgCK governs operations and materialises ontology -> operational
//!     schema / routing.
//!
//! The governed write path (ckp.bootstrap_kernel / validate / seal / verify)
//! ships as bootstrap SQL (PL/pgSQL) and works today. The Rust focus is the
//! background worker: an embedded NATS Core server (hand-rolled, src/nats/,
//! behind the `embedded-nats` feature) + the affordance compile loop. S3 now
//! brings up the raw NATS Core listener; later stages connect that listener to
//! the governed SPI dispatch path described in
//! docs/specs/2026-05-16-pgck-core-design.md.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::time::Duration;

pgrx::pg_module_magic!();

// Bgworker tick interval. Tighter under `nats-client` because the
// publish_drain reads ckp.outbox each tick — visible publish latency
// is ~ TICK_INTERVAL / 2 on average. Under `embedded-nats` (or
// without any NATS feature) the embedded server runs on its own
// thread and the tick is mostly idle; 5s is fine.
#[cfg(feature = "nats-client")]
const TICK_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(not(feature = "nats-client"))]
const TICK_INTERVAL: Duration = Duration::from_secs(5);

// The `embedded-nats` profile (S3, dev/unit-tests) and the `nats-client`
// profile (S4, canonical bundle/cluster) are mutually exclusive — one
// hosts a NATS server inside pgck.so, the other connects out to a real
// nats-server. Enabling both is a configuration error: they'd race for
// :4222 or duplicate publish paths. See SPEC.PGCK.NATS-BIDIRECTIONAL.v0.2
// §2 and TASKS.PGCK.S4-BUNDLED-NATS.v0.1.
#[cfg(all(feature = "embedded-nats", feature = "nats-client"))]
compile_error!(
    "features `embedded-nats` and `nats-client` are mutually exclusive — \
     `embedded-nats` makes pgCK host its own NATS Core server (S3 / dev), \
     `nats-client` makes pgCK a client of the bundled or cluster nats-server \
     (S4 / canonical). Pick exactly one, or neither for the minimal build."
);

mod bgworker;
#[cfg(feature = "embedded-nats")]
mod nats;
#[cfg(feature = "nats-client")]
mod nats_client;
#[cfg(feature = "nats-client")]
mod publish_drain;
// ε-materialize over-budget drain (T6). SPI-only, no NATS dependency — always compiled.
mod materialize_drain;
// Auth-callout JWT verifier (F-A / SPEC.OAUTH2 §3.3). Pure, offline EdDSA verification against an
// in-memory realm JWK — no NATS, no network, no pg — so it compiles + unit-tests under any feature.
mod jwt_verify;

// Auth-callout responder (SPEC.OAUTH2 §3.2/§3.3) — pgCK-owned admittance. Consumes
// jwt_verify to turn a verified CONNECT token into a signed NATS user-JWT. Gated
// under nats-client (it needs the NATS account NKey + the transport to run).
#[cfg(feature = "nats-client")]
mod auth_callout;

// F1-inbound (CKA-4) — the WSS governed-write bridge. The relay enqueues inbound
// actions; the bgworker tick runs ckp.dispatch and replies on result.kernel.*.
// In-kernel replacement for the external Go relay's inbound half.
#[cfg(feature = "nats-client")]
mod inbound_dispatch;

// GUCs for the `nats-client` profile. Registered once in _PG_init and
// read on bgworker boot (S4 step 5). Defaults make the canonical
// in-container bundle layout work out of the box: pgCK talks to the
// bundled nats-server on localhost:4222 with no JetStream stream
// (Core-only publish path until the operator provisions a stream).
#[cfg(feature = "nats-client")]
static PGCK_NATS_URL: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(Some(c"nats://127.0.0.1:4222"));
#[cfg(feature = "nats-client")]
static PGCK_NATS_JS_STREAM: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);

// OIDC auth-callout config (F1 / SPEC.OAUTH2 §3.3). The realm public key + issuer + audience are
// DELIVERED BY CONFIG, exactly like the other Keycloak params — no `.well-known` fetch, no egress
// HTTP. Absent → tokens are not verified (anonymous), never a failure.
#[cfg(feature = "nats-client")]
static PGCK_OIDC_JWKS: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);
#[cfg(feature = "nats-client")]
static PGCK_OIDC_ISSUER: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);
#[cfg(feature = "nats-client")]
static PGCK_OIDC_AUDIENCE: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);

// The NATS account seed (`SA…`) the auth-callout responder signs AuthorizationResponses
// with (SPEC.OAUTH2 §3.2). The matching public key (`A…`) is the `issuer` in the broker's
// `auth_callout` stanza — the deployment generates the pair and delivers the seed here.
// SECRET: superuser-only. Absent → the responder is not started (broker admittance
// stays whatever the broker config says — dev compose unchanged).
#[cfg(feature = "nats-client")]
static PGCK_NATS_ACCOUNT_SEED: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);

/// Snapshot of the `pgck.nats_url` GUC. Read by bgworker boot to
/// connect the async-nats client; default makes the in-container
/// bundle layout (LOCAL-WSS-DEV.v0.2 §2) work without configuration.
#[cfg(feature = "nats-client")]
pub(crate) fn nats_url() -> String {
    PGCK_NATS_URL
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "nats://127.0.0.1:4222".to_string())
}

/// Snapshot of the `pgck.nats_js_stream` GUC. `None` (or empty string)
/// means the JS publish arm is disabled — drain only emits NATS Core
/// publishes; downstream durability is the operator's concern.
#[cfg(feature = "nats-client")]
pub(crate) fn nats_js_stream() -> Option<String> {
    PGCK_NATS_JS_STREAM
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
}

/// Snapshot of the `pgck.nats_account_seed` GUC. Read once at bgworker boot like the
/// OIDC trio — deliver in `postgresql.conf`; rotation = restart. `None`/empty ⇒ the
/// callout responder does not start.
#[cfg(feature = "nats-client")]
pub(crate) fn nats_account_seed() -> Option<String> {
    PGCK_NATS_ACCOUNT_SEED
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.trim().is_empty())
}

/// Load the OIDC auth config ONCE from the `pgck.oidc_*` GUCs (operator/env-delivered), parse the
/// realm JWKS into memory, and cache it. Absent or unparseable config → `None` → the auth-callout
/// admits anonymously (tokens NOT verified) — never a failure. The verified `sub` this later gates
/// becomes the `ckp.requester` the seal path persists (F-A). Used by the callout responder (piece 3).
#[cfg(feature = "nats-client")]
pub(crate) fn oidc_auth_config() -> Option<&'static crate::jwt_verify::AuthConfig> {
    static OIDC_CFG: std::sync::OnceLock<Option<crate::jwt_verify::AuthConfig>> =
        std::sync::OnceLock::new();
    OIDC_CFG
        .get_or_init(|| {
            let jwks = PGCK_OIDC_JWKS.get()?.to_string_lossy().into_owned();
            let issuer = PGCK_OIDC_ISSUER.get()?.to_string_lossy().into_owned();
            let audience = PGCK_OIDC_AUDIENCE.get()?.to_string_lossy().into_owned();
            // The #22 contract, named at the moment it is violated: this GUC carries
            // the JWKS DOCUMENT, never its URL. pgCK has no egress in the live path
            // by design, so the delivery side pulls the document at init and
            // pre-populates it — pre-populated, no egress is ever required. A URL
            // here parses as not-JSON and identity silently stays anonymous, so say
            // exactly what happened and whose fix it is.
            if jwks.trim_start().starts_with("http://") || jwks.trim_start().starts_with("https://")
            {
                log!(
                    "pgck: pgck.oidc_jwks carries a URL, not the JWKS document — pgCK never \
                     fetches (no egress in the live path). The DELIVERY side must pull the \
                     document at init and pre-populate this GUC with the JSON. Tokens NOT \
                     verified (anonymous) until it does."
                );
                return None;
            }
            match crate::jwt_verify::AuthConfig::from_parts(&jwks, &issuer, &audience) {
                Ok(cfg) => {
                    log!("pgck: OIDC auth-config loaded — tokens verified in-memory against the configured realm JWK");
                    Some(cfg)
                }
                Err(e) => {
                    log!("pgck: OIDC auth-config present but unparseable ({e:?}); tokens NOT verified (anonymous)");
                    None
                }
            }
        })
        .as_ref()
}

// Ship the working governed-write path as the extension's bootstrap SQL.
// BASELINE INSTALL (pgCK#31, flatten half). The 31-chunk migration chain is retired
// from the build and replaced by one install, generated by CK-org from this repo's
// own chain-built reference and proven against the obligation pgCK set in PASS-13:
// a fresh install produces an IDENTICAL routine set — 80 routines, identical
// signatures, none gained, none lost.
//
// NAMESPACE-NEUTRAL BY CONSTRUCTION. CK-org generated the baseline on the v3.11
// namespace, which fused two independent changes: collapsing 31 files into 1, and
// migrating v3.8 -> v3.11. Landed together they cannot be reviewed or reverted
// separately, and landing the v3.11 form against the v3.8 ontology is a measured
// silent fake green (PASS-17). So this file is generated at the CURRENT namespace:
// the flatten becomes a provable no-op, and the namespace migration is #41's,
// atomic with root adoption.
//
// The chain was never an upgrade path. pgck--0.3.1--0.3.2.sql and
// pgck--0.4.0--0.4.1.sql are ABSENT FROM THE REPO, so it could not replay from any
// earlier version and nothing reported that. Retained on disk as history.
extension_sql_file!("../sql/pgck-baseline.sql", name = "pgck_baseline");

// Install-from-zero completeness. MUST remain the LAST sql include — its closing
// floor pass re-asserts the pgrdf floor and re-pins ck_participant to exactly the
// dispatch door, covering everything earlier statements created.
//
// Build identity (ckp.version / ckp.build_id) is emitted into the generated
// install by pgrx from the `ckp` module below; an EXISTING database only runs
// upgrade scripts, so the pair must also ship in the matching sql/pgck--A--B.sql.
// Nothing is included here for it: the install path already has it.
extension_sql_file!(
    "../sql/pgck--0.4.1--0.4.2.sql",
    name = "pgck_install_completeness",
    // ckp::version / ckp::build_id are listed so the identity pair is emitted
    // BEFORE this file. Without it pgrx placed the pair after the closing
    // Ring-1 loop, so on a fresh install the two escaped the hardening while
    // the upgrade path (which re-runs the loop last) caught them — measured as
    // the only secdef/owner drift between otherwise identical catalogs. The
    // invariant is that this file is the LAST sql include, covering every
    // object anything earlier created — including pgrx-emitted functions.
    requires = ["pgck_baseline", ckp::version, ckp::build_id]
);

/// Database the pgCK bridge worker attaches to (`connect_worker_to_spi`). It MUST
/// be the database where `CREATE EXTENSION pgck` ran — the worker drains
/// `ckp.outbox` from there. Default `postgres`; override with `pgck.worker_database`.
/// Always compiled (the worker runs in every build, independent of the NATS feature).
static PGCK_WORKER_DATABASE: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);

/// Whether the auth-callout admits an UNVERIFIED connection to the anonymous tier
/// (subscribe-only on the public event stream, no publish) or refuses it outright.
///
/// Default `true`, which preserves the documented fail-open-to-anonymous behaviour —
/// flipping it silently would disconnect every current consumer. Set `false` to make
/// admittance fail-closed: an absent, forged, malformed or expired token is REFUSED
/// rather than downgraded. The identity floor is unaffected either way — a forged
/// token is never admitted as its claimed identity in either mode.
#[cfg(feature = "nats-client")]
static PGCK_ADMIT_ANONYMOUS: pgrx::GucSetting<bool> = pgrx::GucSetting::<bool>::new(true);

/// The kernels this deployment hosts (comma-separated). The auth-callout mints
/// event/result/input grants per kernel from this set (pgCK#30) instead of a
/// hardcoded `pgCK` literal — a `demo`/`Dictionary` deployment grants on its own
/// subjects. Default `pgCK` preserves the single-kernel deployment unchanged.
/// 0.4.78 — the default is the CANONICAL spelling. It shipped as `pgCK`, which
/// this substrate's own canonicalizer REFUSES: `project.resolve {"segment":"pgCK"}`
/// on a fresh install answers *"kernel id 'pgCK' is not canonical, no sealed kernel
/// carries it and no kernel graph stands behind it — use 'pgck'"*, and
/// `germinate_kernel` refuses the same name. So the callout minted event/result/input
/// grants on a transport segment no fact could ever be sealed under. It looked
/// healthy only where a canonical twin happened to be sealed, because clause-2 twin
/// resolution rescued it — an accident, absent on exactly the fresh installs this
/// default exists to serve. Gated by s70 on both planes, with the negative control.
#[cfg(feature = "nats-client")]
static PGCK_KERNELS: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(Some(c"pgck"));

/// Snapshot of `pgck.admit_anonymous` (default `true`).
///
/// FFI — bgworker (postgres-attached) thread ONLY. pgrx 0.19 asserts
/// single-threaded FFI (`guc.rs:194`), and the first live callout request on the
/// relay's async thread panicked exactly there, killing the responder task
/// silently: every subsequent CONNECT timed out after the broker's 2s callout
/// wait. The async side reads [`callout_policy`] instead — a cache this
/// thread refreshes each tick, which is also what keeps #32's Sighup semantics
/// (tighten without a restart) true.
#[cfg(feature = "nats-client")]
pub(crate) fn admit_anonymous() -> bool {
    PGCK_ADMIT_ANONYMOUS.get()
}

/// The callout policy cache: (admit_anonymous, kernels). Written by the bgworker
/// thread ([`refresh_callout_policy`], each tick), read by the callout responder
/// on the relay thread — never postgres FFI from the async side.
#[cfg(feature = "nats-client")]
static CALLOUT_POLICY: std::sync::RwLock<Option<(bool, Vec<String>)>> =
    std::sync::RwLock::new(None);

/// Refresh the callout policy cache from the GUCs. bgworker thread only (FFI).
/// Called once before the relay spawns and again every tick, so a Sighup'd
/// `pgck.admit_anonymous=false` reaches the responder within one tick interval.
#[cfg(feature = "nats-client")]
pub(crate) fn refresh_callout_policy() {
    let fresh = (admit_anonymous(), configured_kernels());
    if let Ok(mut w) = CALLOUT_POLICY.write() {
        *w = Some(fresh);
    }
}

/// The cached (admit_anonymous, kernels) for the responder. Thread-safe, no FFI.
/// Before the first refresh (unreachable in practice — the bgworker refreshes
/// before spawning the relay) it falls back to the GUC defaults: admit `true`,
/// kernel set `["pgck"]` — the CANONICAL spelling (0.4.78). This fallback carried
/// `pgCK` while the GUC default carried `pgCK`: two copies of one non-canonical
/// literal, both minting grants on a segment the canonicalizer refuses.
#[cfg(feature = "nats-client")]
pub(crate) fn callout_policy() -> (bool, Vec<String>) {
    CALLOUT_POLICY
        .read()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| (true, vec!["pgck".to_string()]))
}

/// The configured kernel set for the auth-callout grant (pgCK#30). Splits
/// `pgck.kernels` on commas, trims, drops empties and any token carrying a NATS
/// subject metacharacter (`.` `*` `>` whitespace) so a kernel name can never
/// widen a grant beyond its own token. Empty result ⇒ the callout mints no
/// kernel-scoped grant (fail-closed), never a silent `pgCK` fallback.
#[cfg(feature = "nats-client")]
pub(crate) fn configured_kernels() -> Vec<String> {
    PGCK_KERNELS
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
        .split(',')
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty() && !k.contains(['.', '*', '>', ' ', '\t', '\r', '\n']))
        .collect()
}

/// Snapshot of `pgck.worker_database` (default `postgres` when unset/empty).
pub(crate) fn worker_database() -> String {
    PGCK_WORKER_DATABASE
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "postgres".to_string())
}

/// Registered at load time (shared_preload_libraries = 'pgck').
/// Spawns the pgCK background worker.
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    // Always-on GUC (the worker exists in every build). Postmaster context: read
    // once when the worker attaches to SPI, so it must be set before startup.
    pgrx::GucRegistry::define_string_guc(
        c"pgck.worker_database",
        c"Database the pgCK bridge worker attaches to (where CREATE EXTENSION pgck ran)",
        c"The worker drains ckp.outbox from here. Default 'postgres'. Set to match your install DB.",
        &PGCK_WORKER_DATABASE,
        pgrx::GucContext::Postmaster,
        pgrx::GucFlags::default(),
    );
    #[cfg(feature = "nats-client")]
    {
        // Admittance policy. Default true preserves the documented fail-open-to-anonymous
        // tier; false makes the auth-callout REFUSE an unverified connection outright
        // instead of downgrading it. Sighup so an operator can tighten without a restart.
        pgrx::GucRegistry::define_bool_guc(
            c"pgck.admit_anonymous",
            c"Admit an unverified connection to the anonymous tier instead of refusing it",
            c"Default on: an absent/forged/malformed token is downgraded to anonymous (subscribe-only, no publish). Off: it is refused. The identity floor is unaffected either way — a forged token is never admitted as its claimed identity.",
            &PGCK_ADMIT_ANONYMOUS,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.nats_url",
            c"URL of the bundled or cluster nats-server pgCK publishes to",
            c"Default `nats://127.0.0.1:4222` matches the in-container bundle layout.",
            &PGCK_NATS_URL,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.nats_js_stream",
            c"JetStream stream name for the durable publish arm (empty = Core-only)",
            c"When set, pgCK also publishes event.kernel.* to this JS stream with a \
             Nats-Msg-Id header carrying ckp.ledger.seq for server-side dedup.",
            &PGCK_NATS_JS_STREAM,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.oidc_jwks",
            c"Realm JWKS (public keys) delivered by config — no .well-known fetch, no egress HTTP",
            c"JWKS JSON ({\"keys\":[…]}); only Ed25519 (OKP) keys are used. Empty = tokens not verified (anonymous).",
            &PGCK_OIDC_JWKS,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.oidc_issuer",
            c"Expected JWT issuer (the configured Keycloak realm issuer URL)",
            c"The token `iss` MUST equal this. Empty = tokens not verified (anonymous).",
            &PGCK_OIDC_ISSUER,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.oidc_audience",
            c"Expected JWT audience (the configured client id)",
            c"The token `aud` MUST include this. Empty = tokens not verified (anonymous).",
            &PGCK_OIDC_AUDIENCE,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.nats_account_seed",
            c"NATS account seed (SA…) the auth-callout responder signs admittance with",
            c"The matching public key (A…) is the broker's auth_callout issuer. SECRET — \
              superuser-only. Empty = the $SYS.REQ.USER.AUTH responder is not started.",
            &PGCK_NATS_ACCOUNT_SEED,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::SUPERUSER_ONLY,
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.kernels",
            c"Kernels this deployment hosts (comma-separated) — the auth-callout grant set",
            c"The callout mints event/result/input subject grants per kernel from this set \
              (pgCK#30), not a hardcoded pgCK literal. Tokens with a NATS metachar (. * > \
              whitespace) are dropped. Default 'pgCK'; empty = no kernel-scoped grant.",
            &PGCK_KERNELS,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
    }

    BackgroundWorkerBuilder::new("pgck-bridge")
        .set_function("pgck_bridge_main")
        .set_library("pgck")
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .load();
}

/// Background worker entrypoint. It parks on the latch, starts the embedded
/// NATS Core listener once, and exits cleanly on SIGTERM. Later stages add the
/// governed SPI dispatch bridge (see `bgworker`).
#[no_mangle]
#[pg_guard]
pub extern "C-unwind" fn pgck_bridge_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    let db = crate::worker_database();
    BackgroundWorker::connect_worker_to_spi(Some(db.as_str()), None);

    log!("pgck: bridge worker starting (database={db})");
    while BackgroundWorker::wait_latch(Some(TICK_INTERVAL)) {
        // SIGHUP wakes the latch (attach_signal_handlers above) but does NOT
        // reload config — a bgworker must do that itself, and this loop never
        // did. So every Sighup-context GUC (pgck.admit_anonymous, pgck.kernels)
        // was in truth restart-bound in the worker: a backend saw the new value
        // while the responder kept minting from the boot-time one. Measured on
        // the bench (ALTER SYSTEM + pg_reload_conf -> backend pgCK,Dictionary,
        // worker still pgCK). Process the config file, then tick — the tick's
        // policy-cache refresh picks the new values up.
        if BackgroundWorker::sighup_received() {
            unsafe { pg_sys::ProcessConfigFile(pg_sys::GucContext::PGC_SIGHUP) };
        }
        bgworker::tick();
    }
    log!("pgck: bridge worker exiting");
}

/// Extension version. The minimal real thing a PG client can call:
/// `SELECT pgck_version();`
///
/// Derived from `CARGO_PKG_VERSION` (== Cargo.toml `version` == `pgck.control`
/// `default_version` == the release tag) so the native self-report can never
/// again drift from the installed extension version. Was a hardcoded
/// `"pgck 0.4.3 (rc3)"` literal that stayed frozen while the extension marched
/// 0.4.3 → 0.4.14 — see the oci-germination pgck_version()-stale NOTIFY.
#[pg_extern]
fn pgck_version() -> &'static str {
    concat!("pgck ", env!("CARGO_PKG_VERSION"))
}

/// The §7 identity pair, in `ckp` — where pgCK's other 81 functions already
/// live, and the only schema pgCK has. There is no schema named `pgck`: the
/// EXTENSION is `pgck`, the SCHEMA is `ckp`. pgRDF's two names coincide, which
/// is the only reason `pgrdf.version()` reads as it does; the pgCK spelling is
/// `ckp.version()`.
///
/// `#[pg_schema]` emits `CREATE SCHEMA IF NOT EXISTS ckp`, and the baseline
/// (`sql/pgck-baseline.sql`) emits the same idempotent statement, so the two
/// cannot conflict whichever order the SQL generator lands them in.
///
/// Placement is load-bearing, not cosmetic: `pg_catalog` is searched before
/// `public`, so a `version()` sitting in `public` answers a bare
/// `SELECT version()` with PostgreSQL's own banner — measured on the bench as
/// `PostgreSQL 18.4 (Debian 18.4-1.pgdg13+1)`. In `ckp` the name cannot be
/// captured by core.
#[pg_schema]
pub mod ckp {
    use pgrx::prelude::*;

    /// Bare semver — the release line this library was cut from.
    ///
    /// Required by SPEC.RUST-BUILDER.CK.v3.11 §7, which fixes the pair every
    /// extension on the shared builder exposes: `version()` names the RELEASE
    /// LINE and is identical across every build of it; `build_id()` names the
    /// BINARY. §10 reads them together.
    ///
    /// Distinct from [`super::pgck_version()`], which stays exactly where and
    /// what it is: prefixed `"pgck <semver>"`, in `public`, because
    /// oci-germination already reads that form. Both derive from
    /// `CARGO_PKG_VERSION`, so they cannot disagree.
    #[pg_extern]
    pub fn version() -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    /// The build this library was compiled from — tag, commits-since, short
    /// commit, and a `-dirty` marker when the tree was not clean.
    ///
    /// **The one identifier that survives a wrong drop.** Version, control file
    /// and install SQL all agree the moment the *control* file is replaced; the
    /// library is loaded separately and by the postmaster. So `ckp.version()`
    /// can report a version the loaded `.so` is not, and every other plane will
    /// agree with it. This does not — it is compiled in.
    ///
    /// **Deliberately narrow.** Any connected role can call it, so it carries
    /// only tag, commits-since, short commit and the dirty marker: no
    /// filesystem paths, host names, or build users. `build_id_carries_no_paths`
    /// enforces that rather than leaving it to review.
    #[pg_extern]
    pub fn build_id() -> &'static str {
        option_env!("PGCK_BUILD_ID").unwrap_or("unknown")
    }
}

#[cfg(test)]
mod tests {

    /// `build_id()` is readable by any connected role, so the disclosure
    /// surface is enforced here rather than left to review. It carries build
    /// IDENTITY, never build ENVIRONMENT.
    #[test]
    fn build_id_carries_no_paths() {
        let id = crate::ckp::build_id();
        assert!(!id.is_empty(), "build_id must never be empty");
        for bad in ["/Users", "/home", "/root", "/tmp", "\\", "@"] {
            assert!(
                !id.contains(bad),
                "build_id must not carry filesystem paths or hosts, found {bad:?} in {id:?}"
            );
        }
    }
    #[test]
    fn version_present() {
        // Asserts the contract: pgck_version() tracks the crate version exactly.
        assert_eq!(
            crate::pgck_version(),
            concat!("pgck ", env!("CARGO_PKG_VERSION"))
        );
    }

    /// SPEC.RUST-BUILDER.CK.v3.11 §7: `version()` is BARE semver from
    /// Cargo.toml. §10 reads it next to `build_id()`, and a consumer parsing it
    /// as a version must not have to strip a prefix first — that is what
    /// `pgck_version()` is for.
    #[test]
    fn version_is_bare_semver() {
        let v = crate::ckp::version();
        assert_eq!(v, env!("CARGO_PKG_VERSION"));
        let parts: Vec<&str> = v.split('.').collect();
        assert_eq!(parts.len(), 3, "expected MAJOR.MINOR.PATCH, got {v:?}");
        for p in parts {
            assert!(
                !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()),
                "non-numeric semver component {p:?} in {v:?}"
            );
        }
    }

    /// The two self-reports read the same source, so they can never drift. This
    /// is the assertion that keeps both spellings honest now that both ship.
    #[test]
    fn version_agrees_with_pgck_version() {
        assert_eq!(
            crate::pgck_version(),
            format!("pgck {}", crate::ckp::version()),
            "pgck_version() must stay version() with the historical prefix"
        );
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // pgck must be preloaded so the bgworker registers.
        vec!["shared_preload_libraries = 'pgck'"]
    }
}
