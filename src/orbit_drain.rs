//! Bgworker tick-loop driver of the orbit queue (C-11, v0.4.109).
//!
//! Each tick: `ckp.orbit_tick()` detects due crossings for every kernel with
//! declared orbit law (ENQUEUE — a crossing never executes at detection) and
//! drains at most four jobs, at most one per kernel (fair — the wait scales
//! with how many kernels are busy, never with how much the busiest queued;
//! SUBSTRATE-SCOPE §4.2). The work is the DRAFT-only score tick: even
//! executed, a crossing seals no vote and applies nothing — the constitutional
//! limit lives in SQL where the probes can measure it.
//!
//! Guarded on `to_regprocedure`: an older extension without the function keeps
//! a silent no-op tick, exactly as an SPI miss already does — the worker must
//! never die because the SQL surface is behind the `.so`. Same error
//! discipline as `materialize_drain`: log and return, never panic.

use pgrx::bgworkers::BackgroundWorker;
use pgrx::log;
use pgrx::spi::Spi;

/// Run one enqueue+drain cycle. Returns the number of jobs completed this
/// tick (0 on empty queue, missing function, or SPI error).
pub fn drain_once() -> usize {
    let drained: Result<i64, pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            let table = client.update(
                "SELECT CASE WHEN to_regprocedure('ckp.orbit_tick()') IS NULL THEN 0
                        ELSE COALESCE(((ckp.orbit_tick())->>'done')::bigint, 0) END",
                None,
                &[],
            )?;
            let mut n: i64 = 0;
            for row in table {
                let v: Option<i64> = row.get(1)?;
                n = v.unwrap_or(0);
            }
            Ok(n)
        })
    });

    match drained {
        Ok(n) => n as usize,
        Err(e) => {
            log!("pgck orbit_drain: spi error during drain: {}", e);
            0
        }
    }
}
