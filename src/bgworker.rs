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
//!     enqueues publishes onto the async-nats thread. Per
//!     `_WIP/SPEC.PGCK.NATS-BIDIRECTIONAL.v0.2` §3 and
//!     `_WIP/TASKS.PGCK.S4-BUNDLED-NATS.v0.1` step 5.
//!
//!   * (no NATS feature) — tick is a no-op; the bgworker still runs so
//!     wait_latch has something to call. Useful for minimal builds that
//!     exercise only the governed SQL path.

#[cfg(any(feature = "embedded-nats", feature = "nats-client"))]
use std::sync::OnceLock;

#[cfg(feature = "embedded-nats")]
static EMBEDDED_SERVER_STARTED: OnceLock<()> = OnceLock::new();

#[cfg(feature = "nats-client")]
static CLIENT_INITIALISED: OnceLock<()> = OnceLock::new();

#[cfg(feature = "embedded-nats")]
fn start_server_once(state: &OnceLock<()>, starter: impl FnOnce()) {
    state.get_or_init(|| {
        starter();
    });
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
        CLIENT_INITIALISED.get_or_init(|| {
            let url = crate::nats_url();
            let js_stream = crate::nats_js_stream();
            // Inbound relay (G2): subscribe input.kernel.pgCK.action.> and
            // fan out as event.kernel.pgCK.<verb> — basic Bob<->Alice + presence.
            crate::nats_client::init_relay(url.clone());
            // Outbound publish thread + outbox drain (CKA-6).
            crate::nats_client::init(url, js_stream);
        });
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
