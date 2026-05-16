//! pgCK — PostgreSQL Concept Kernel extension.
//!
//! Composition:
//!   * pgRDF (required) holds the ontology + runs SHACL/SPARQL.
//!   * pgCK governs operations, owns NATS (embedded server + WSS client),
//!     and materialises ontology -> operational schema / routing.
//!
//! The governed write path (ckp.bootstrap_kernel / validate / seal / verify)
//! ships as bootstrap SQL (PL/pgSQL) and works today. The Rust focus is the
//! background worker: embedded NATS server + gateway WSS client + the
//! affordance compile loop.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::time::Duration;

pgrx::pg_module_magic!();

mod bgworker;

// Ship the working governed-write path as the extension's bootstrap SQL.
extension_sql_file!("../sql/pgck--0.1.0.sql", name = "pgck_bootstrap");

/// Registered at load time (shared_preload_libraries = 'pgck').
/// Spawns the pgCK background worker that runs the NATS server + bridge.
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    BackgroundWorkerBuilder::new("pgck-bridge")
        .set_function("pgck_bridge_main")
        .set_library("pgck")
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .load();
}

/// Background worker entrypoint. Owns the embedded NATS server lifecycle and
/// the WSS-client bridge loop. See `bgworker::run`.
#[no_mangle]
#[pg_guard]
pub extern "C-unwind" fn pgck_bridge_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(
        SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM,
    );
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);

    log!("pgck: bridge worker starting");
    while BackgroundWorker::wait_latch(Some(Duration::from_secs(5))) {
        if BackgroundWorker::sighup_received() {
            // reload config / recompile affordances on ontology change
        }
        bgworker::tick();
    }
    log!("pgck: bridge worker exiting");
}

/// Thin SQL-callable wrappers. The substance is the bootstrap SQL; these
/// exist so a PG client can drive lifecycle operations by name.
#[pg_extern]
fn pgck_version() -> &'static str {
    "pgck 0.1.0 (rc3)"
}

/// Trigger an affordance recompile (also fired automatically by the
/// CK-graph change trigger once the bgworker arms it).
#[pg_extern]
fn pgck_recompile_affordances() -> bool {
    bgworker::recompile_affordances()
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn version_present() {
        assert_eq!(crate::pgck_version(), "pgck 0.1.0 (rc3)");
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // pgck must be preloaded so the bgworker registers
        vec!["shared_preload_libraries = 'pgrdf,pgck'"]
    }
}
