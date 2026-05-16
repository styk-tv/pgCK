//! pgCK background worker — the NATS half.
//!
//! REQUIREMENT 1 (two NATS roles in one extension):
//!   * Embedded NATS *server*: message fabric for every concept kernel in the
//!     pod for this project. Spawned as a child `nats-server` process (no
//!     mature pure-Rust NATS server; the binary is baked into the pod image).
//!   * NATS *client*: connects to (a) the embedded server for in-pod kernel
//!     traffic and (b) the gateway WSS stream that has already passed the
//!     Envoy SecurityPolicy (TLS + OIDC-JWT) at the Azure Container App front.
//!     pgCK trusts the post-Envoy stream — it enforces governance, not authn.
//!
//! REQUIREMENT 2 (PG-client-driven): every inbound message is turned into a
//! `ckp.*` SQL call over SPI. The database connection is the API.
//!
//! Status: skeleton. Lifecycle + loop shape are real; NATS wiring is TODO,
//! marked clearly. The governed write path it calls (`ckp.seal`) already works.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::process::{Child, Command};
use std::sync::OnceLock;

static NATS_SERVER: OnceLock<Option<Child>> = OnceLock::new();

/// Spawn the embedded NATS server once (idempotent). The pod image ships
/// `nats-server` on PATH; we own its lifecycle from inside Postgres so the
/// fabric is up exactly when the database is.
fn ensure_embedded_server() {
    NATS_SERVER.get_or_init(|| {
        match Command::new("nats-server").arg("-p").arg("4222").spawn() {
            Ok(child) => {
                log!("pgck: embedded nats-server spawned (pid {})", child.id());
                Some(child)
            }
            Err(e) => {
                warning!("pgck: could not spawn nats-server: {e} (is it on PATH?)");
                None
            }
        }
    });
}

/// One scheduler tick. Called by the bgworker loop on the latch interval.
pub fn tick() {
    ensure_embedded_server();
    // TODO: drive the async-nats client:
    //   1. connect to embedded server (in-pod kernel fabric)
    //   2. connect to gateway WSS subject (post-Envoy stream)
    //   3. for each subscribed affordance topic, on message:
    //        BackgroundWorker::transaction(|| Spi::run(
    //          "SELECT ckp.seal($1,$2)", &[id.into(), body.into()]));
    //   4. publish result on ckp:outTopic
    // The subscription set is materialised from the CK graph (see
    // `recompile_affordances`). For now the loop just keeps the server alive.
}

/// Materialise the routing table from the ontology: enumerate
/// `ckp:Affordance` rows in the kernel CK graph and (re)bind NATS
/// subscriptions to match. Called on boot and on every CK-graph change.
pub fn recompile_affordances() -> bool {
    let mut count = 0i64;
    let _ = BackgroundWorker::transaction(|| {
        Spi::connect(|client| {
            // pgRDF SPARQL over the kernel CK graph (graph id 2 by convention).
            let q = r#"
                SELECT count(*) AS n FROM pgrdf.sparql($q$
                  PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
                  SELECT ?aff ?inTopic WHERE {
                    ?aff a ckp:Affordance ; ckp:inTopic ?inTopic . }
                $q$, 2) AS t(aff text, inTopic text)
            "#;
            if let Ok(tup) = client.select(q, None, &[]) {
                if let Some(row) = tup.first().get_one::<i64>().ok().flatten() {
                    count = row;
                }
            }
            Ok::<(), pgrx::spi::Error>(())
        })
        .ok();
    });
    log!("pgck: recompile_affordances — {count} affordance(s) in CK graph");
    // TODO: diff against live subscription set and add/remove on the client.
    true
}
