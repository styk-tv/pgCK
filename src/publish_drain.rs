//! Bgworker tick-loop drain of `ckp.outbox`.
//!
//! Per S4 step 3 (revised 2026-05-29 — outbox approach replaced the
//! original LISTEN/NOTIFY plan because pgrx 0.16 has no usable
//! `pg_sys::Async_*` consumer surface). Each bgworker tick:
//!
//!   1. Calls `BackgroundWorker::transaction(...)` to enter SPI.
//!   2. Issues `DELETE FROM ckp.outbox WHERE seq IN (SELECT seq FROM
//!      ckp.outbox ORDER BY seq LIMIT 100) RETURNING ...` — atomic
//!      drain of up to 100 rows.
//!   3. For each drained row: decode the JSONB header map, call into
//!      `nats_client::publish` (and `publish_js` if `pgck.nats_js_stream`
//!      is set), stamp `Nats-Msg-Id` from the ledger.seq for JS dedup.
//!
//! Failures (SPI errors, channel-send errors) log via `pgrx::log!` and
//! continue — never panic, never fail-stop the bgworker. Rows that were
//! drained by the DELETE but failed to enqueue into the nats_client
//! thread are lost (matches the publish-edge lossy model per
//! `SPEC.CKP.v3.8-rc-09-nats §4.2`).

use pgrx::bgworkers::BackgroundWorker;
use pgrx::log;
use pgrx::spi::Spi;

use crate::nats_client;

const DRAIN_QUERY: &str = "\
DELETE FROM ckp.outbox \
WHERE seq IN (SELECT seq FROM ckp.outbox ORDER BY seq LIMIT 100) \
RETURNING ledger_seq, subject, payload, headers";

struct DrainedRow {
    ledger_seq: i64,
    subject: String,
    payload: Vec<u8>,
    headers: serde_json::Value,
}

/// Drain up to 100 outbox rows and enqueue them on the nats_client
/// thread. Returns the number of rows drained (0 on error or empty).
/// Called once per bgworker tick.
pub fn drain_once() -> usize {
    let drained: Result<Vec<DrainedRow>, pgrx::spi::Error> =
        BackgroundWorker::transaction(|| {
            Spi::connect_mut(|client| {
                let table = client.update(DRAIN_QUERY, None, &[])?;
                let mut out = Vec::new();
                for row in table {
                    let ledger_seq: Option<i64> = row.get(1)?;
                    let subject: Option<String> = row.get(2)?;
                    let payload: Option<Vec<u8>> = row.get(3)?;
                    let headers: Option<pgrx::JsonB> = row.get(4)?;
                    if let (Some(ls), Some(s), Some(p), Some(h)) =
                        (ledger_seq, subject, payload, headers)
                    {
                        out.push(DrainedRow {
                            ledger_seq: ls,
                            subject: s,
                            payload: p,
                            headers: h.0,
                        });
                    }
                }
                Ok(out)
            })
        });

    let drained = match drained {
        Ok(rows) => rows,
        Err(e) => {
            log!("pgck publish_drain: spi error during drain: {}", e);
            return 0;
        }
    };

    if drained.is_empty() {
        return 0;
    }

    let js_stream = crate::nats_js_stream();
    let count = drained.len();

    for r in drained {
        let core_headers = json_to_header_pairs(&r.headers);

        if let Err(e) = nats_client::publish(&r.subject, &r.payload, &core_headers) {
            log!(
                "pgck publish_drain: core enqueue failed: subject={} err={}",
                r.subject,
                e
            );
        }

        if js_stream.is_some() {
            let mut js_headers = core_headers.clone();
            js_headers.push(("Nats-Msg-Id".to_string(), r.ledger_seq.to_string()));
            if let Err(e) = nats_client::publish_js(&r.subject, &r.payload, &js_headers) {
                log!(
                    "pgck publish_drain: js enqueue failed: subject={} err={}",
                    r.subject,
                    e
                );
            }
        }
    }

    count
}

fn json_to_header_pairs(value: &serde_json::Value) -> Vec<(String, String)> {
    let Some(obj) = value.as_object() else {
        return Vec::new();
    };
    obj.iter()
        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
        .collect()
}
