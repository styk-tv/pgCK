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
//! behind the `embedded-nats` feature) + the affordance compile loop. This
//! v0.1.1 ships the worker as a quiet skeleton — the NATS half lands per
//! docs/specs/2026-05-16-pgck-core-design.md.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::time::Duration;

pgrx::pg_module_magic!();

mod bgworker;
#[cfg(feature = "embedded-nats")]
mod nats;

// Ship the working governed-write path as the extension's bootstrap SQL.
extension_sql_file!("../sql/pgck--0.1.1.sql", name = "pgck_bootstrap");

/// Registered at load time (shared_preload_libraries = 'pgck').
/// Spawns the pgCK background worker.
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    BackgroundWorkerBuilder::new("pgck-bridge")
        .set_function("pgck_bridge_main")
        .set_library("pgck")
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .load();
}

/// Background worker entrypoint. Quiet skeleton for v0.1.1: it parks on the
/// latch and exits cleanly on SIGTERM. The embedded NATS Core server + the
/// affordance bridge loop are added per the core design (see `bgworker`).
#[no_mangle]
#[pg_guard]
pub extern "C-unwind" fn pgck_bridge_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);

    log!("pgck: bridge worker starting");
    while BackgroundWorker::wait_latch(Some(Duration::from_secs(5))) {
        bgworker::tick();
    }
    log!("pgck: bridge worker exiting");
}

/// Extension version. The minimal real thing a PG client can call:
/// `SELECT pgck_version();`
#[pg_extern]
fn pgck_version() -> &'static str {
    "pgck 0.1.1 (rc3)"
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn version_present() {
        assert_eq!(crate::pgck_version(), "pgck 0.1.1 (rc3)");
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
