//! pgCK background worker — the NATS half (skeleton for v0.1.0).
//!
//! Per docs/superpowers/specs/2026-05-16-pgck-core-design.md:
//!
//!   * The embedded NATS *server* is a hand-rolled NATS Core module
//!     (`src/nats/`, behind the `embedded-nats` feature) compiled into
//!     `pgck.so` — NOT a child `nats-server` process. The dev loop may
//!     use a stock `nats-server` sidecar container until that lands.
//!   * Threading: a dedicated thread owns the tokio runtime + the NATS
//!     connection; this bgworker's main thread owns SPI and runs
//!     `BackgroundWorker::transaction(|| Spi::run("SELECT ckp.seal..."))`
//!     per inbound message, bridged by an mpsc channel.
//!
//! v0.1.0 ships this as a quiet, fmt/clippy-clean skeleton so the
//! distribution pipeline (GitHub Release + GHCR OCI artifact) is proven
//! end-to-end. The server + bridge are filled in per the implementation
//! plan; the governed write path (`ckp.seal`) it will call already works.

/// One scheduler tick. Called by the bgworker loop on the latch interval.
/// No-op until the embedded NATS Core server and the affordance bridge
/// are wired (core design §4, §5).
pub fn tick() {
    // intentionally empty for v0.1.0
}
