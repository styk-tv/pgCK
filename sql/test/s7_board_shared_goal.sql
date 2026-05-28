-- CKB-2: worked example — four Tasks across four kernels sharing one Goal.
-- Acceptance (per _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §6):
--   After sealing one Goal + four Tasks (target_kernel ∈ {pgCK, pgRDF,
--   CK.Lib.Js, oci-germination}) part_of the same Goal, SPARQL
--   recovers exactly four distinct kernel URNs from the projected board.
--
-- Self-contained: loads shapes from the repo's ontology/ rather than
-- relying on the runtime's /ontology mount. Each kernel name and the
-- Goal id pass through ckp.urn_normalise() at projection time so the
-- expected URN reflects the canonicalised form (e.g. CK.Lib.Js -> ck-lib-js).
--
-- Run: psql -f sql/test/s7_board_shared_goal.sql

\set t `cat ontology/task.ttl`
\set g `cat ontology/goal.ttl`

SELECT pgrdf.add_graph('urn:ckp:s7-test/kernel/board') AS board_g \gset
SELECT pgrdf.clear_graph(:board_g);
SELECT pgrdf.parse_turtle(:'t', :board_g, 'urn:ckp:s7-test/module/task#');
SELECT pgrdf.parse_turtle(:'g', :board_g, 'urn:ckp:s7-test/module/goal#');
SELECT pgrdf.materialize(:board_g);

SET ckp.project = 's7-test';

-- Seal the shared Goal.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.7/Goal',
    'https://conceptkernel.org/ontology/v3.7/goal_id', 'v3.8-pgxn-release',
    'https://conceptkernel.org/ontology/v3.7/title',  'Ship CKP v3.8 to PGXN',
    'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-28T00:00:00Z'
  );
BEGIN
  PERFORM ckp.seal('S7-G', v_body);
END $$;

-- Seal four Tasks, one per contributing kernel.
DO $$
DECLARE
  v_kernels text[] := ARRAY['pgCK', 'pgRDF', 'CK.Lib.Js', 'oci-germination'];
  v_kernel  text;
  v_idx     int := 0;
  v_body    jsonb;
BEGIN
  FOREACH v_kernel IN ARRAY v_kernels LOOP
    v_idx := v_idx + 1;
    v_body := jsonb_build_object(
      'type', 'https://conceptkernel.org/ontology/v3.7/Task',
      'https://conceptkernel.org/ontology/v3.7/task_id', 'S7-T-' || v_idx,
      'https://conceptkernel.org/ontology/v3.7/title', 'land contribution for ' || v_kernel,
      'https://conceptkernel.org/ontology/v3.7/part_of_goal', 'v3.8-pgxn-release',
      'https://conceptkernel.org/ontology/v3.7/target_kernel', v_kernel,
      'https://conceptkernel.org/ontology/v3.7/lifecycle_state', 'pending',
      'https://conceptkernel.org/ontology/v3.7/priority', v_idx,
      'https://conceptkernel.org/ontology/v3.7/queue_seq', v_idx,
      'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-28T00:00:00Z'
    );
    PERFORM ckp.seal('S7-T-' || v_idx, v_body);
  END LOOP;
END $$;

-- SPARQL recovery: distinct kernels under the shared Goal.
DO $$
DECLARE
  v_count int;
  v_query text := '
    PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
    SELECT DISTINCT ?kernel FROM <urn:ckp:s7-test/kernel/board>
    WHERE {
      ?t a ckp:Task ;
         ckp:part_of_goal  <ckp://Goal#' || ckp.urn_normalise('v3.8-pgxn-release') || '> ;
         ckp:target_kernel ?kernel .
    }';
BEGIN
  SELECT count(*) INTO v_count FROM pgrdf.sparql(v_query);
  IF v_count <> 4 THEN
    RAISE EXCEPTION 's7 FAIL: expected 4 distinct kernels under the shared Goal, got %', v_count;
  END IF;
END $$;

\echo s7_board_shared_goal: PASS
