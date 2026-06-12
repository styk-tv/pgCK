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
//! behind the `embedded-nats` feature) + the affordance compile loop. S3 now
//! brings up the raw NATS Core listener; later stages connect that listener to
//! the governed SPI dispatch path described in
//! docs/specs/2026-05-16-pgck-core-design.md.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::time::Duration;

pgrx::pg_module_magic!();

// Bgworker tick interval. Tighter under `nats-client` because the
// publish_drain reads ckp.outbox each tick — visible publish latency
// is ~ TICK_INTERVAL / 2 on average. Under `embedded-nats` (or
// without any NATS feature) the embedded server runs on its own
// thread and the tick is mostly idle; 5s is fine.
#[cfg(feature = "nats-client")]
const TICK_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(not(feature = "nats-client"))]
const TICK_INTERVAL: Duration = Duration::from_secs(5);

// The `embedded-nats` profile (S3, dev/unit-tests) and the `nats-client`
// profile (S4, canonical bundle/cluster) are mutually exclusive — one
// hosts a NATS server inside pgck.so, the other connects out to a real
// nats-server. Enabling both is a configuration error: they'd race for
// :4222 or duplicate publish paths. See SPEC.PGCK.NATS-BIDIRECTIONAL.v0.2
// §2 and TASKS.PGCK.S4-BUNDLED-NATS.v0.1.
#[cfg(all(feature = "embedded-nats", feature = "nats-client"))]
compile_error!(
    "features `embedded-nats` and `nats-client` are mutually exclusive — \
     `embedded-nats` makes pgCK host its own NATS Core server (S3 / dev), \
     `nats-client` makes pgCK a client of the bundled or cluster nats-server \
     (S4 / canonical). Pick exactly one, or neither for the minimal build."
);

mod bgworker;
#[cfg(feature = "embedded-nats")]
mod nats;
#[cfg(feature = "nats-client")]
mod nats_client;
#[cfg(feature = "nats-client")]
mod publish_drain;

// GUCs for the `nats-client` profile. Registered once in _PG_init and
// read on bgworker boot (S4 step 5). Defaults make the canonical
// in-container bundle layout work out of the box: pgCK talks to the
// bundled nats-server on localhost:4222 with no JetStream stream
// (Core-only publish path until the operator provisions a stream).
#[cfg(feature = "nats-client")]
static PGCK_NATS_URL: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(Some(c"nats://127.0.0.1:4222"));
#[cfg(feature = "nats-client")]
static PGCK_NATS_JS_STREAM: pgrx::GucSetting<Option<std::ffi::CString>> =
    pgrx::GucSetting::<Option<std::ffi::CString>>::new(None);

/// Snapshot of the `pgck.nats_url` GUC. Read by bgworker boot to
/// connect the async-nats client; default makes the in-container
/// bundle layout (LOCAL-WSS-DEV.v0.2 §2) work without configuration.
#[cfg(feature = "nats-client")]
pub(crate) fn nats_url() -> String {
    PGCK_NATS_URL
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "nats://127.0.0.1:4222".to_string())
}

/// Snapshot of the `pgck.nats_js_stream` GUC. `None` (or empty string)
/// means the JS publish arm is disabled — drain only emits NATS Core
/// publishes; downstream durability is the operator's concern.
#[cfg(feature = "nats-client")]
pub(crate) fn nats_js_stream() -> Option<String> {
    PGCK_NATS_JS_STREAM
        .get()
        .as_ref()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
}

// Ship the working governed-write path as the extension's bootstrap SQL.
extension_sql_file!("../sql/pgck--0.2.2.sql", name = "pgck_bootstrap");

// CI-A-4 (CKP v3.9 §7, SPEC.ROADMAP.v3.9.CHECKLIST index 24): the Ring-0
// role-isolation floor. Runs after the bootstrap so its REVOKE/GRANT apply to
// the ckp + pgrdf objects the bootstrap defines. Fresh CREATE EXTENSION includes
// this; existing installs reach it via the sql/pgck--0.2.2--0.2.3.sql upgrade.
extension_sql_file!(
    "../sql/pgck--0.2.2--0.2.3.sql",
    name = "pgck_ci_a4_role_floor",
    requires = ["pgck_bootstrap"]
);

// CI-A-3 (CKP v3.9 §3, SPEC.ROADMAP.v3.9.CHECKLIST index 23): the frozen Ring-1
// primitive set — SECURITY DEFINER wrappers owned by ck_substrate, the only code
// paths permitted to invoke pgrdf.*. Requires the role floor (CI-A-4).
extension_sql_file!(
    "../sql/pgck--0.2.3--0.2.4.sql",
    name = "pgck_ci_a3_ring1",
    requires = ["pgck_ci_a4_role_floor"]
);

// CI-A-2 (CKP v3.9 §7/§2, SPEC.ROADMAP.v3.9.CHECKLIST index 22): the locked
// four-tuple ckp.dispatch door — SECURITY DEFINER owned by ck_substrate, granted
// to ck_participant and nothing else. Requires the role floor (CI-A-4).
extension_sql_file!(
    "../sql/pgck--0.2.4--0.2.5.sql",
    name = "pgck_ci_a2_dispatch_door",
    requires = ["pgck_ci_a4_role_floor"]
);

// CI-A-1 (CKP v3.9 §7, SPEC.ROADMAP.v3.9.CHECKLIST index 21): Track A ship-it —
// ck_participant LOGIN so the sidecar harness demonstrates the §7 exit over a real
// connection (the F-H "agent with DB creds" shape).
extension_sql_file!(
    "../sql/pgck--0.2.5--0.2.6.sql",
    name = "pgck_ci_a1_participant_login",
    requires = ["pgck_ci_a2_dispatch_door"]
);

// Critical Isolation Alpha (v0.3.0): bring the existing web2 verb surface
// (sql/dispatch.sql — task.create/update, snapshot.*, edge.create, notify, instances.*,
// …) INTO the extension so it can be governed, then floor it. Without this the web2
// verbs are an orphan that was never loaded; with it, web2 keeps working under the floor.
extension_sql_file!(
    "../sql/dispatch.sql",
    name = "pgck_web2_dispatch",
    requires = ["pgck_ci_a4_role_floor"]
);

// Floor the web2 dispatch: SECURITY DEFINER owned by ck_substrate, granted to
// ck_participant; PUBLIC denied. Requires the verbs to be loaded first.
extension_sql_file!(
    "../sql/pgck--0.2.6--0.3.0.sql",
    name = "pgck_alpha_web2_floor",
    requires = ["pgck_web2_dispatch"]
);

// CKP v3.9 Track B (sealed registry + typed dispatch). CI-B-4 adds the exact-match
// affordance registry index + lookup; CI-B-3/CI-B-2 accrete here. Requires the floor
// (ck_substrate owns pgrdf + the ckp internals).
extension_sql_file!(
    "../sql/pgck--0.3.0--0.3.1.sql",
    name = "pgck_trackb_registry",
    requires = ["pgck_alpha_web2_floor"]
);

// CKP v3.9 Track C (apply-time plan compiler + epoch invalidation). CI-C-4 adds the
// ckp.plans table; CI-C-3/CI-C-2 accrete here. Requires the registry — plans are keyed by
// the same (kernel, verb, epoch).
extension_sql_file!(
    "../sql/pgck--0.3.2--0.3.3.sql",
    name = "pgck_trackc_plans",
    requires = ["pgck_trackb_registry"]
);

// CKP v3.9 Track D (the governance type plane). CI-D-5 adds kernel.propose_change;
// CI-D-4/D-3/D-2 accrete here. Requires the plan compiler (apply recompiles via Track C).
extension_sql_file!(
    "../sql/pgck--0.3.3--0.3.4.sql",
    name = "pgck_trackd_governance",
    requires = ["pgck_trackc_plans"]
);

// CKP v3.9 Track E (the enumerable typed read surface). CI-E-5 adds instance.query;
// CI-E-4/E-3/E-2 accrete here. Requires the governance plane (concept.match is sealed
// via proposal/apply at CI-E-2).
extension_sql_file!(
    "../sql/pgck--0.3.4--0.3.5.sql",
    name = "pgck_tracke_reads",
    requires = ["pgck_trackd_governance"]
);

// v0.4.3: instance.retire (the spec's last unbuilt verb) + validate_report scratch
// graph by-IRI. Chained BEFORE the completeness floor pass below.
extension_sql_file!(
    "../sql/pgck--0.4.2--0.4.3.sql",
    name = "pgck_v043_retire",
    requires = ["pgck_tracke_reads"]
);

// v0.4.4: Tier 2 (1/3) — generic typed instance.create (ckp.create_typed). Routes a
// uniform {type,…fields} body by type against the kernel's declared shape; ckp.seal's
// required-props gate makes the type real. Routing added in sql/dispatch.sql.
// Gate: sql/test/s38_generic_typed_create.sql.
extension_sql_file!(
    "../sql/pgck--0.4.3--0.4.4.sql",
    name = "pgck_v044_generic_create",
    requires = ["pgck_v043_retire"]
);

// v0.4.5: Tier 2 (2/3) — governance _graph_apply. ckp.apply now translates a passed
// Proposal's op into the kernel graph (ckp._op_to_ttl -> ckp.apply_shape_ttl: stage ->
// meta-fence -> copy_graph into urn:ckp:<proj>/kernel/ck) BEFORE the epoch bump, so a
// quorum-approved add_property actually constrains the next seal. Gate: s39.
extension_sql_file!(
    "../sql/pgck--0.4.4--0.4.5.sql",
    name = "pgck_v045_graph_apply",
    requires = ["pgck_v044_generic_create"]
);

// v0.4.6: Tier 2 (3/3a) — reach edge-materialization. edge.create now also writes the
// traversable quad <src> <pred> <tgt> into urn:ckp:<proj>/edges (ckp.materialize_edge),
// so instance.reach traverses participant-created links (not only pre-seeded quads).
// Gate: s40.
extension_sql_file!(
    "../sql/pgck--0.4.5--0.4.6.sql",
    name = "pgck_v046_reach_edges",
    requires = ["pgck_v045_graph_apply"]
);

// v0.4.7: Tier 2 (3/3b) — governed query affordances (§6.3 concept.match form). A query is
// declared via the governance plane (propose add_affordance{verb,query,params} -> vote ->
// apply), compiled into ckp.plans + a plane='query' registry row, and dispatched by binding
// typed caller params into the sealed query text. Makes the plan compiler load-bearing.
// Gate: s41.
extension_sql_file!(
    "../sql/pgck--0.4.6--0.4.7.sql",
    name = "pgck_v047_query_affordance",
    requires = ["pgck_v046_reach_edges"]
);

// v0.4.8: v0.5 roadmap T1 — instance.query derived QueryShape. ckp.query validates filter
// keys against the type's DECLARED sh:property set (read from the kernel graph), resolving a
// short key to its property IRI; unshaped types keep the regex fallback. Gate: s42.
extension_sql_file!(
    "../sql/pgck--0.4.7--0.4.8.sql",
    name = "pgck_v048_query_shape",
    requires = ["pgck_v047_query_affordance"]
);

// v0.4.9: v0.5 roadmap T2 — link/reach declared predicate set. ckp.declared_predicates reads the
// kernel graph's sh:path set; ckp.reach + edge.create gate the predicate on it (namespace-allowlist
// fallback when the kernel declares none). Gate: s43.
extension_sql_file!(
    "../sql/pgck--0.4.8--0.4.9.sql",
    name = "pgck_v049_declared_predicates",
    requires = ["pgck_v048_query_shape"]
);

// v0.4.10: v0.5 roadmap T3 — per-kernel sealed transition map. ckp._op_to_ttl translates
// set_transition_map into ckp:allowsTransition triples; ckp.apply_shape_ttl's fence admits the
// governance transition vocab; ckp.transition reads the type's sealed map (global config fallback).
// Gate: s44.
extension_sql_file!(
    "../sql/pgck--0.4.9--0.4.10.sql",
    name = "pgck_v0410_transition_map",
    requires = ["pgck_v049_declared_predicates"]
);

// Install-from-zero completeness (v0.4.2, answers oci-germination's install-cascade
// NOTIFY): seal-path tables exist AT CREATE EXTENSION owned by ck_substrate, pgrdf
// floor re-asserted, every ckp callable uniformly floored, participant re-pinned to
// exactly the dispatch door(s). MUST remain the LAST sql include — its closing floor
// pass covers everything earlier files created. Gate: scripts/smoke-s34-fresh-install.sh.
extension_sql_file!(
    "../sql/pgck--0.4.1--0.4.2.sql",
    name = "pgck_install_completeness",
    requires = ["pgck_v0410_transition_map"]
);

/// Registered at load time (shared_preload_libraries = 'pgck').
/// Spawns the pgCK background worker.
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    #[cfg(feature = "nats-client")]
    {
        pgrx::GucRegistry::define_string_guc(
            c"pgck.nats_url",
            c"URL of the bundled or cluster nats-server pgCK publishes to",
            c"Default `nats://127.0.0.1:4222` matches the in-container bundle layout.",
            &PGCK_NATS_URL,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
        pgrx::GucRegistry::define_string_guc(
            c"pgck.nats_js_stream",
            c"JetStream stream name for the durable publish arm (empty = Core-only)",
            c"When set, pgCK also publishes event.kernel.* to this JS stream with a \
             Nats-Msg-Id header carrying ckp.ledger.seq for server-side dedup.",
            &PGCK_NATS_JS_STREAM,
            pgrx::GucContext::Sighup,
            pgrx::GucFlags::default(),
        );
    }

    BackgroundWorkerBuilder::new("pgck-bridge")
        .set_function("pgck_bridge_main")
        .set_library("pgck")
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .load();
}

/// Background worker entrypoint. It parks on the latch, starts the embedded
/// NATS Core listener once, and exits cleanly on SIGTERM. Later stages add the
/// governed SPI dispatch bridge (see `bgworker`).
#[no_mangle]
#[pg_guard]
pub extern "C-unwind" fn pgck_bridge_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);

    log!("pgck: bridge worker starting");
    while BackgroundWorker::wait_latch(Some(TICK_INTERVAL)) {
        bgworker::tick();
    }
    log!("pgck: bridge worker exiting");
}

/// Extension version. The minimal real thing a PG client can call:
/// `SELECT pgck_version();`
#[pg_extern]
fn pgck_version() -> &'static str {
    "pgck 0.4.3 (rc3)"
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_present() {
        assert_eq!(crate::pgck_version(), "pgck 0.4.3 (rc3)");
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
