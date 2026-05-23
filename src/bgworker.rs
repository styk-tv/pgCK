//! pgCK background worker — S3 hosts the embedded NATS listener.
//!
//! Per docs/specs/2026-05-16-pgck-core-design.md:
//!
//!   * The embedded NATS *server* is a hand-rolled NATS Core module
//!     (`src/nats/`, behind the `embedded-nats` feature) compiled into
//!     `pgck.so` — NOT a child `nats-server` process.
//!   * Threading: a dedicated thread owns the tokio runtime + the NATS
//!     connection; this bgworker's main thread owns SPI and runs
//!     `BackgroundWorker::transaction(|| Spi::run("SELECT ckp.seal..."))`
//!     per inbound message, bridged by an mpsc channel.
//!
//! S3 only starts the raw TCP listener on `:4222`. The governed SPI bridge
//! lands later; this file deliberately keeps the listener thread isolated
//! from Postgres access.

#[cfg(feature = "embedded-nats")]
use std::sync::OnceLock;

#[cfg(feature = "embedded-nats")]
static SERVER: OnceLock<()> = OnceLock::new();

#[cfg(feature = "embedded-nats")]
fn start_server_once(state: &OnceLock<()>, starter: impl FnOnce()) {
    state.get_or_init(|| {
        starter();
    });
}

/// One scheduler tick. Called by the bgworker loop on the latch interval.
/// S3 starts the embedded NATS listener once; later stages add the SPI bridge.
pub fn tick() {
    #[cfg(feature = "embedded-nats")]
    start_server_once(&SERVER, || {
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
}

#[cfg(test)]
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
