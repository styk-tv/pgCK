//! pgCK background worker — bridges the governed seal path to the NATS bus.
//!
//! Two feature-gated modes (mutually exclusive; src/lib.rs enforces):
//!
//!   * `embedded-nats` (S3, dev / unit-tests) — hosts the hand-rolled
//!     NATS Core server from `src/nats/` on a dedicated tokio thread.
//!     The server is started once on the first tick and runs until the
//!     bgworker exits. Per docs/specs/2026-05-16-pgck-core-design.md §4.
//!
//!   * `nats-client` (S4, canonical bundle / cluster) — bgworker is a
//!     NATS client of the bundled `nats-server` (`pgck.nats_url` GUC,
//!     default `nats://127.0.0.1:4222`). First tick spawns the async-nats
//!     thread (`nats_client::init`); every tick drains up to 100 rows
//!     from `ckp.outbox` via SPI (`publish_drain::drain_once`) and
//!     enqueues publishes onto the async-nats thread. The contract: the
//!     outbox is the only publish source, the drain is at-least-once, and
//!     the bgworker never blocks the postmaster on a broker outage.
//!
//!   * (no NATS feature) — tick is a no-op; the bgworker still runs so
//!     wait_latch has something to call. Useful for minimal builds that
//!     exercise only the governed SQL path.

use pgrx::bgworkers::BackgroundWorker;
use pgrx::spi::Spi;
use std::sync::OnceLock;

#[cfg(feature = "embedded-nats")]
static EMBEDDED_SERVER_STARTED: OnceLock<()> = OnceLock::new();

/// Latches true once `ckp.outbox` exists in the worker's database. The bridge
/// worker starts at postmaster — possibly before `CREATE EXTENSION pgck` has run
/// in its target database (`pgck.worker_database`), or attached to a database
/// that never gets the extension. The SPI drains below reference `ckp.*`; a
/// "relation does not exist" ereport aborts the tick's transaction and kills the
/// worker (exit code 1), so it never returned after the extension was created.
static PGCK_READY: OnceLock<()> = OnceLock::new();

/// Cheap per-tick probe that WAITS for the extension instead of dying on it.
/// `to_regclass` returns NULL (never an error) when the relation is absent, so
/// this is safe to run before the extension exists. Latches on first success so
/// steady-state ticks skip the probe.
fn pgck_ready() -> bool {
    if PGCK_READY.get().is_some() {
        return true;
    }
    let present = BackgroundWorker::transaction(|| {
        matches!(
            Spi::get_one::<bool>("SELECT to_regclass('ckp.outbox') IS NOT NULL"),
            Ok(Some(true))
        )
    });
    if present {
        let _ = PGCK_READY.set(());
    }
    present
}

#[cfg(feature = "nats-client")]
static CLIENT_INITIALISED: OnceLock<()> = OnceLock::new();

#[cfg(feature = "embedded-nats")]
fn start_server_once(state: &OnceLock<()>, starter: impl FnOnce()) {
    state.get_or_init(|| {
        starter();
    });
}

/// Roster-union ledger refresh cadence — time-based so it lands ~5s apart on
/// both tick intervals (100ms embedded / 5s plain), and the per-tick cost of
/// the union stays a lock read, not an SPI query.
#[cfg(feature = "nats-client")]
const LEDGER_REFRESH_EVERY: std::time::Duration = std::time::Duration::from_secs(5);
#[cfg(feature = "nats-client")]
static LEDGER_LAST: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);

/// Refresh the ledger half of the roster union (2026-08-29): every sealed,
/// unretired `ckp:Kernel` instance's transport segment, read via SPI on the
/// bgworker thread (the only thread that may). Gated behind `pgck_ready()` by
/// the caller; a NULL/absent result keeps the previous set — the union can
/// only add to the GUC, never break it. The segment comes from the sealed
/// `@id` (`urn:ckp:<segment>/kernel`), canonical-lowercase by the pattern, so
/// a non-canonical historical spelling simply never enters the grant set.
#[cfg(feature = "nats-client")]
fn refresh_ledger_kernels() {
    let due = match LEDGER_LAST.lock() {
        Ok(mut g) => match *g {
            Some(t) if t.elapsed() < LEDGER_REFRESH_EVERY => false,
            _ => {
                *g = Some(std::time::Instant::now());
                true
            }
        },
        Err(_) => false,
    };
    if !due {
        return;
    }
    let csv = BackgroundWorker::transaction(|| {
        Spi::get_one::<String>(
            "SELECT string_agg(DISTINCT seg, ',') FROM ( \
               SELECT substring(body->>'@id' FROM '^urn:ckp:([a-z0-9-]+)/kernel$') AS seg \
               FROM ckp.instances \
               WHERE body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Kernel' \
                 AND NOT body ? 'https://conceptkernel.org/ontology/v3.11/core#retiredAtEpoch' \
             ) s WHERE seg IS NOT NULL",
        )
        .ok()
        .flatten()
    });
    if let Some(csv) = csv {
        crate::set_ledger_kernels(csv.split(',').map(str::to_string).collect());
    }
}

/// One scheduler tick. Called by the bgworker loop on the latch interval.
pub fn tick() {
    #[cfg(feature = "embedded-nats")]
    start_server_once(&EMBEDDED_SERVER_STARTED, || {
        std::thread::spawn(|| {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");

            runtime.block_on(async {
                if let Err(error) = crate::nats::server::run("0.0.0.0:4222").await {
                    eprintln!("pgck: nats server exited: {error}");
                }
            });
        });
    });

    #[cfg(feature = "nats-client")]
    {
        // Callout policy (admit_anonymous + kernels) is FFI-read HERE, every tick,
        // into the cache the responder's async thread reads — pgrx 0.19 panics on
        // GUC reads from a non-postgres thread, and the per-tick refresh is what
        // keeps #32's Sighup semantics without cross-thread FFI. Runs BEFORE the
        // relay first spawns so the cache is never empty when a request arrives.
        crate::refresh_callout_policy();

        CLIENT_INITIALISED.get_or_init(|| {
            let url = crate::nats_url();
            let js_stream = crate::nats_js_stream();
            // F1: load the OIDC auth-config once from the pgck.oidc_* GUCs (in-memory verify, no
            // network) BEFORE the relay starts — the callout responder latches it. Logs whether
            // tokens will be verified or admissions stay anonymous.
            let auth = crate::oidc_auth_config();
            // F1 piece 3: pgCK-owned admittance. Seed present + valid ACCOUNT key ⇒ the relay
            // connection also answers $SYS.REQ.USER.AUTH. GUCs are read HERE (bgworker owns pg);
            // the async side only receives the built context.
            let callout = crate::nats_account_seed()
                .and_then(|seed| {
                    let kp = crate::auth_callout::parse_account_seed(&seed);
                    if kp.is_none() {
                        pgrx::log!(
                            "pgck: pgck.nats_account_seed is set but not a valid ACCOUNT seed \
                             (SA…) — auth-callout responder NOT started"
                        );
                    }
                    kp
                })
                .map(|account| crate::nats_client::CalloutContext { auth, account });
            // Inbound relay (F1-inbound): governed WSS writes via ckp.dispatch, identity from
            // the broker-enforced subject scope.
            crate::nats_client::init_relay(url.clone(), callout);
            // Outbound publish thread + outbox drain (CKA-6).
            crate::nats_client::init(url, js_stream);
        });
    }

    // Resilience gate: the NATS client (above) connects regardless, but every
    // drain below touches ckp.* via SPI. Skip them until the extension exists in
    // this worker's database — WAIT, don't die. Once ready, latch and stop probing.
    if !pgck_ready() {
        return;
    }

    #[cfg(feature = "nats-client")]
    {
        // F1-inbound: run any WSS-published governed actions the relay queued,
        // replying on result.kernel.pgCK.<verb>. SPI-bound, so it runs here (not
        // the relay's async thread).
        // Roster union, ledger half — refreshed here (SPI-bound, extension
        // present), consumed by the next tick's refresh_callout_policy.
        refresh_ledger_kernels();
        crate::inbound_dispatch::drain_and_dispatch();
        let _ = crate::publish_drain::drain_once();
    }

    // ε-materialize over-budget drain (T6): SPI-only, independent of NATS, so it runs every
    // tick regardless of feature set. Normally a cheap no-op (Model A is lazy — the job queue
    // is empty unless a read handed a build off over budget).
    let _ = crate::materialize_drain::drain_once();
}

#[cfg(all(test, feature = "embedded-nats"))]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::OnceLock;

    use super::start_server_once;

    #[test]
    fn start_server_once_is_idempotent() {
        let state = OnceLock::new();
        let starts = AtomicUsize::new(0);

        start_server_once(&state, || {
            starts.fetch_add(1, Ordering::SeqCst);
        });
        start_server_once(&state, || {
            starts.fetch_add(1, Ordering::SeqCst);
        });

        assert_eq!(starts.load(Ordering::SeqCst), 1);
    }
}
