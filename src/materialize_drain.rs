//! Bgworker tick-loop drain of `ckp.materialize_job` (ε-materialize over-budget handoff, T6).
//!
//! Each bgworker tick completes at most one queued build. The drain logic lives in the SQL
//! function `ckp.materialize_drain_once()` (picks one job `FOR UPDATE SKIP LOCKED`, rebuilds at
//! the CURRENT (ε, watermark) so a superseded job is never stale, atomically publishes the
//! phenotype pointer, deletes the job). This shim is a thin SPI caller — same pattern and error
//! discipline as `publish_drain`: SPI errors log via `pgrx::log!` and return 0; never panic,
//! never fail-stop the bgworker. The queue is normally empty (Model A is lazy; jobs appear only
//! on the over-budget read path), so this is a cheap no-op tick most of the time.

use pgrx::bgworkers::BackgroundWorker;
use pgrx::log;
use pgrx::spi::Spi;

/// Complete one queued materialize job. Returns 1 if a job was drained, 0 if the queue was
/// empty or on SPI error. Called once per bgworker tick.
pub fn drain_once() -> usize {
    let drained: Result<i32, pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            let table = client.update("SELECT ckp.materialize_drain_once()", None, &[])?;
            let mut n: i32 = 0;
            for row in table {
                let v: Option<i32> = row.get(1)?;
                n = v.unwrap_or(0);
            }
            Ok(n)
        })
    });

    match drained {
        Ok(n) => n as usize,
        Err(e) => {
            log!("pgck materialize_drain: spi error during drain: {}", e);
            0
        }
    }
}
