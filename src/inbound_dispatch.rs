//! F1-inbound — the WSS governed-write bridge (SPEC.PGCK.NATS.LLD §7, the CKA-4 seam).
//!
//! The old external Go relay did two jobs: drain `ckp.outbox` → NATS (pgCK's
//! `-nats` build now owns that) AND run `ckp.dispatch` for a WSS-published action
//! and reply on `result.kernel.<K>.<verb>`. This module is the in-kernel
//! replacement for that inbound half, so the Go relay can be dropped entirely.
//!
//! The relay thread (`nats_client`) can't touch SPI, so it [`enqueue`]s each
//! inbound `input.kernel.pgCK.action.<verb>` action here; the bgworker `tick()`
//! calls [`drain_and_dispatch`], which runs the governed `ckp.dispatch` in its own
//! transaction with `ckp.requester` set from the connection's identity (server-set,
//! never payload-asserted — TR-02), and hands the typed jsonb result back to the
//! publish thread for `result.kernel.pgCK.<verb>`, echoing the inbound `Trace-Id`.
#![allow(dead_code)]

use pgrx::bgworkers::BackgroundWorker;
use pgrx::spi::Spi;
use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

/// One inbound governed action awaiting dispatch on the bgworker thread.
pub struct InboundAction {
    /// The governed verb, parsed from `input.kernel.pgCK.action.<verb>`.
    pub verb: String,
    /// The message body — the `ckp.dispatch` payload (a JSON object).
    pub payload: Vec<u8>,
    /// Where the typed result goes: `result.kernel.pgCK.<verb>`.
    pub result_subject: String,
    /// Inbound headers to echo on the reply (Trace-Id correlation).
    pub headers: Vec<(String, String)>,
    /// The verified participant (`sub`) when the connection was admitted with a
    /// verified identity; `None` ⇒ anonymous (the SQL mints `anon:<nonce>`).
    pub identity: Option<String>,
}

/// Bound the queue so a stalled tick can't grow it without limit — the client
/// re-dispatches on its Trace-Id timeout, so dropping the tail is safe.
const MAX_QUEUE: usize = 1000;

fn queue() -> &'static Mutex<VecDeque<InboundAction>> {
    static Q: OnceLock<Mutex<VecDeque<InboundAction>>> = OnceLock::new();
    Q.get_or_init(|| Mutex::new(VecDeque::new()))
}

/// Enqueue an inbound action (called from the relay thread).
pub fn enqueue(action: InboundAction) {
    if let Ok(mut q) = queue().lock() {
        if q.len() < MAX_QUEUE {
            q.push_back(action);
        }
    }
}

fn take_all() -> Vec<InboundAction> {
    match queue().lock() {
        Ok(mut q) => q.drain(..).collect(),
        Err(_) => Vec::new(),
    }
}

/// Drain queued inbound actions and dispatch each through the governed door.
/// Called from the bgworker `tick()` (which owns SPI). Each action runs in its own
/// transaction; the typed result (or a structured `ok:false` on error, so the
/// client's Trace-Id correlation still resolves) is queued for publish.
pub fn drain_and_dispatch() {
    for action in take_all() {
        let result = dispatch_one(&action);
        let _ =
            crate::nats_client::publish(&action.result_subject, result.as_bytes(), &action.headers);
    }
}

fn dispatch_one(action: &InboundAction) -> String {
    let verb = action.verb.clone();
    let payload = String::from_utf8_lossy(&action.payload).to_string();
    let identity = action.identity.clone();

    let out: Result<Option<String>, pgrx::spi::Error> = BackgroundWorker::transaction(|| {
        Spi::connect_mut(|client| {
            // Identity is server-set from the verified connection, never the
            // payload (TR-02), and LOCAL to this txn so it can't leak across
            // actions. Anonymous ⇒ leave `ckp.requester` unset so the seal path
            // mints `urn:ckp:participant:anon:<nonce>` (never an empty slug).
            if let Some(sub) = &identity {
                client.update(
                    "SELECT set_config('ckp.requester', $1, true)",
                    None,
                    &[sub.clone().into()],
                )?;
            }
            let table = client.update(
                "SELECT ckp.dispatch($1, $2::jsonb)::text",
                Some(1),
                &[verb.clone().into(), payload.clone().into()],
            )?;
            let mut result = None;
            for row in table {
                result = row.get::<String>(1)?;
            }
            Ok(result)
        })
    });

    match out {
        Ok(Some(json)) => json,
        Ok(None) => r#"{"ok":false,"error":"dispatch returned null"}"#.to_string(),
        Err(e) => format!(
            r#"{{"ok":false,"error":"dispatch failed: {}"}}"#,
            e.to_string().replace('"', "'")
        ),
    }
}
