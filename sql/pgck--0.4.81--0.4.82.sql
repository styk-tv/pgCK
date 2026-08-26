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

-- SECOND functional change (both roads, one act): ckp.project_links validates
-- against the composed surface, not the never-seeded board graph (pgRDF#134,
-- resolved as OUR defect — the engine's vacuity refusal was correct). The seal
-- gate remains the law; a board-declaring project's Task is judged there
-- (measured: M4 = urn:ckp:board/shape/Task). Projection namespace residue is
-- deliberately deferred (bundle agreements; tests/v312-tdd case 16).
CREATE OR REPLACE FUNCTION ckp.project_links(p_project text, p_instance_id text, p_body jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type        text := p_body->>'type';
  v_short_type  text;
  v_board_iri   text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g     bigint;
  v_scratch_iri text;
  v_scratch_g   bigint;
  v_id          text;
  v_goal_id     text;
  v_kernel      text;
  v_label       text;
  v_subject     text;
  v_ttl         text;
  v_validation  jsonb;
  v_results     jsonb;
  v_added       bigint := 0;
BEGIN
  -- Class detection: only Task and Goal project link triples in v0.1.
  IF v_type ILIKE '%/Task' OR v_type = 'ckp:Task' THEN
    v_short_type := 'Task';
  ELSIF v_type ILIKE '%/Goal' OR v_type = 'ckp:Goal' THEN
    v_short_type := 'Goal';
  ELSE
    RETURN 0;
  END IF;

  -- Build the Turtle that represents this instance's link triples.
  IF v_short_type = 'Task' THEN
    v_id      := p_body->>'urn:ckp:board/task_id';
    v_goal_id := p_body->>'urn:ckp:board/part_of_goal';
    v_kernel  := p_body->>'urn:ckp:board/target_kernel';

    -- Bodies missing any required link field reach the SHACL gate below
    -- with an empty/partial scratch graph — the gate catches them and
    -- rolls back the seal. That keeps the rejection path single-sourced.
    v_subject := 'ckp://Task#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> . '
      || '<%s> a ckp:Task',
      v_subject);

    IF v_goal_id IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:part_of_goal <ckp://Goal#%s>',
        ckp.urn_normalise(v_goal_id));
    END IF;
    IF v_kernel IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:target_kernel <ckp://Kernel#%s>',
        ckp.urn_normalise(v_kernel));
    END IF;
    v_ttl := v_ttl || ' .';

  ELSIF v_short_type = 'Goal' THEN
    v_id    := p_body->>'urn:ckp:board/goal_id';
    v_label := p_body->>'urn:ckp:board/title';

    v_subject := 'ckp://Goal#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp:  <https://conceptkernel.org/ontology/v3.11/core#> . '
      || '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> . '
      || '<%s> a ckp:Goal',
      v_subject);

    IF v_label IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; rdfs:label "%s"',
        replace(v_label, '"', '\"'));
    END IF;
    v_ttl := v_ttl || ' .';
  END IF;

  -- CKB-4 pre-flight: refuse to validate if the project board's shapes
  -- are missing (stale /ontology/ mount, project never imported the
  -- modules, etc.). shapes_self_test RAISES on missing shape — propagate.
  PERFORM ckp.shapes_self_test(p_project);

  -- Project into a private scratch graph so the gate decides whether the
  -- triples ever land in the board. add_graph is get-or-create; clear
  -- before parse so a duplicate seal (same id) doesn't pollute.
  v_board_g     := pgrdf.add_graph(v_board_iri);
  v_scratch_iri := format('urn:ckp:%s/seal-scratch/%s', p_project, p_instance_id);
  v_scratch_g   := pgrdf.add_graph(v_scratch_iri);
  PERFORM pgrdf.clear_graph(v_scratch_g);
  PERFORM pgrdf.parse_turtle(v_ttl, v_scratch_g, 'urn:ckp:projection#');

  -- SHACL gate — against the COMPOSED SURFACE, the same law ckp.seal reads.
  -- 0.4.82: this validated against the BOARD graph, which nothing seeds since
  -- the board vocabulary retired from CORE (0.4.51) — get-or-create minted it
  -- empty, and pgRDF 0.6.34's vacuity refusal exposed the path (pgRDF#134,
  -- resolved as ours; the refusal was correct). The composed surface is the one
  -- law (F10). KNOWN RESIDUE, deliberately not fixed in this release: the link
  -- TTL above types core#Task/core#Goal — IRIs no surface declares — so this
  -- gate selects ZERO focus nodes and passes silently; the SEAL gate remains
  -- the real law (a board-declaring project's Task is judged there, M4 =
  -- board/shape/Task, measured). The projection namespace mismatch is
  -- tests/v312-tdd case 16's RED and the next train's fix; changing projection
  -- semantics mid-release would break the oci-germination bundle agreements.
  v_validation := pgrdf.validate(v_scratch_g, ckp._composed_shapes(p_project));

  IF NOT (v_validation->>'conforms')::boolean THEN
    v_results := v_validation->'results';
    PERFORM pgrdf.drop_graph(v_scratch_g);
    RAISE EXCEPTION 'ckp.seal: SHACL gate rejected % % — % violation(s); first: %',
      v_short_type,
      p_instance_id,
      jsonb_array_length(v_results),
      v_results->0->>'sourceConstraintComponent';
  END IF;

  -- Validation passed: commit the same Turtle into the board graph and
  -- discard the scratch.
  v_added := pgrdf.parse_turtle(v_ttl, v_board_g, 'urn:ckp:projection#');
  PERFORM pgrdf.drop_graph(v_scratch_g);

  RETURN v_added::int;
END;
$function$
;

DO $$
BEGIN
  RAISE NOTICE 'pgck 0.4.82: v3.12 FINAL is the boot default (7de02b35…); aligned to pgRDF v0.6.34. Existing kernels unchanged — re-grounding is a governed act.';
END $$;
