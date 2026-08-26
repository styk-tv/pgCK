-- pgck--0.4.81--0.4.82.sql — v3.12 FINAL BECOMES THE BOOT DEFAULT; ALIGNED TO
-- pgRDF v0.6.34.
--
-- The one functional change, shipped on BOTH roads in one act (the 5134c99
-- discipline): ckp.boot() defaults to /ontology/v3.12/core.ttl. The install
-- path gets it from the baseline; this migration re-declares the procedure so
-- a warm ALTER EXTENSION UPDATE gets the identical default. Re-booting is NOT
-- performed here — boot is an explicit act, and a live kernel re-grounds only
-- by governance, never as an upgrade side effect.
--
--   (1) ontology/v3.12/core.ttl is FINAL (operator ruling 2026-08-26): the RC2
--       bytes promoted unchanged, digest 7de02b35…, sidecar
--       core.ttl.wave-3.12.sha256. Audited mechanically at promotion: 19/19
--       §2 vocabulary additions present; 0 IRIs minted outside the namespace
--       line (v3.12 binds v3.11/core# — the LAW carries the version); V3'
--       property-reach 94 declared / 94 reached / 0 unreached; the constants'
--       negative controls refuse naming their paths (weightDissent sign gate,
--       thresholdDiscard sh:lessThan thresholdPromote) while lawful values
--       fire nothing — tests/v312-tdd cases 11, 12, 12b.
--   (2) the smoke gates run against pgRDF v0.6.34 (attested; Justfile
--       pgrdf_ver 0.6.25 -> 0.6.34): E0 typed refusals ride through dispatch
--       verbatim (verified by inspection); T-NULL cannot reach the seal path
--       (no runtime pgrdf.graph_digest calls — audited).
--   (3) container-unpacked ontologies are STALE by construction until
--       oci-germination cuts a bundle against pgck >= 0.4.82 — this repo's
--       ontology/ tree is the only current source (ontology/README.md).

CREATE OR REPLACE PROCEDURE ckp.boot(IN p_core_ttl_path text DEFAULT '/ontology/v3.12/core.ttl'::text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE v_core INT; v_ttl TEXT; v_shapes INT;
BEGIN
  PERFORM pgrdf.shmem_reset();
  -- P0-A0 (pgCK#23): resolve the core graph BY IRI and record the id it got.
  -- Never assume an id from config. Two paths bound graphs — one by explicit
  -- id from ckp.config, one by IRI with an auto-assigned id — and whichever ran
  -- first won the id. That left core_graph_id pointing at the kernel graph and
  -- boot raising 'graph_id 1 is bound to a different IRI' on every run, so the
  -- core ontology was never loaded and every ckp.validate(_, core) conformed
  -- trivially against an empty shapes graph.
  v_core := pgrdf.add_graph('urn:ckp:core');
  INSERT INTO ckp.config(k,v) VALUES ('core_graph_id', v_core::text)
    ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
  -- Fail loudly. An empty core graph is not a runnable state: it makes the
  -- seal's own ledger/proof gate unreachable and every core constraint inert.
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF v_shapes = 0 THEN
    RAISE EXCEPTION 'ckp.boot: core ontology at % loaded 0 sh:NodeShape — refusing to run with an unenforced core', p_core_ttl_path;
  END IF;
  -- Ring repair (fresh install, measured 2026-08-08): the per-graph tables
  -- this boot just created belong to the CALLING superuser — boot cannot be a
  -- ck_substrate definer because pg_read_file is superuser-gated — while every
  -- internal that reads them (ckp._composed_shapes and the rest of the ring-1
  -- definer set) runs as ck_substrate. On a fresh install the completeness
  -- floor ran at CREATE EXTENSION, before these tables existed, so the first
  -- seal died inside pgrdf.copy_graph with `permission denied for table
  -- _pgrdf_quads_g1`. Re-assert the substrate floor over pgrdf exactly as the
  -- completeness pass states it, now covering the dynamically created tables.
  -- (The lasting fix is a grant at creation inside pgrdf.add_graph — filed
  -- against pgRDF; this covers every graph boot itself creates.)
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
  RAISE NOTICE 'ckp.boot: core graph % loaded from %, % NodeShapes', v_core, p_core_ttl_path, v_shapes;
END;
$procedure$
;

DO $$
BEGIN
  RAISE NOTICE 'pgck 0.4.82: v3.12 FINAL is the boot default (7de02b35…); aligned to pgRDF v0.6.34. Existing kernels unchanged — re-grounding is a governed act.';
END $$;
