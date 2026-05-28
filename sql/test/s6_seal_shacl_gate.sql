-- CKB-4: ckp.seal() SHACL gate.
-- Acceptance: bad Task (missing part_of_goal) raises during seal with the
-- error message naming ckp:MinCountConstraintComponent and the bad-instance
-- row never enters ckp.instances. Good Task seals normally.
--
-- This fixture is self-contained: it loads the SHACL-bearing ontology
-- modules from the repo into a fresh project board graph rather than
-- relying on the runtime's /ontology mount, so it's stable across
-- container versions.
--
-- Run: psql -f sql/test/s6_seal_shacl_gate.sql

\set t `cat ontology/task.ttl`
\set g `cat ontology/goal.ttl`

SELECT pgrdf.add_graph('urn:ckp:s6-test/kernel/board') AS board_g \gset
SELECT pgrdf.clear_graph(:board_g);
SELECT pgrdf.parse_turtle(:'t', :board_g, 'urn:ckp:s6-test/module/task#');
SELECT pgrdf.parse_turtle(:'g', :board_g, 'urn:ckp:s6-test/module/goal#');
SELECT pgrdf.materialize(:board_g);

SET ckp.project = 's6-test';

-- Good Task: link predicates present → seal succeeds.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.7/Task',
    'https://conceptkernel.org/ontology/v3.7/task_id', 'S6-OK',
    'https://conceptkernel.org/ontology/v3.7/title', 'good',
    'https://conceptkernel.org/ontology/v3.7/part_of_goal', 'g1',
    'https://conceptkernel.org/ontology/v3.7/target_kernel', 'pgCK',
    'https://conceptkernel.org/ontology/v3.7/lifecycle_state', 'pending',
    'https://conceptkernel.org/ontology/v3.7/priority', 1,
    'https://conceptkernel.org/ontology/v3.7/queue_seq', 1,
    'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-28T00:00:00Z'
  );
BEGIN
  PERFORM ckp.seal('S6-OK', v_body);
END $$;

-- Bad Task: missing part_of_goal → seal must RAISE with MinCount.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.7/Task',
    'https://conceptkernel.org/ontology/v3.7/task_id', 'S6-BAD',
    'https://conceptkernel.org/ontology/v3.7/title', 'missing part_of_goal',
    'https://conceptkernel.org/ontology/v3.7/target_kernel', 'pgCK',
    'https://conceptkernel.org/ontology/v3.7/lifecycle_state', 'pending',
    'https://conceptkernel.org/ontology/v3.7/priority', 1,
    'https://conceptkernel.org/ontology/v3.7/queue_seq', 1,
    'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-28T00:00:00Z'
  );
  v_caught text;
BEGIN
  BEGIN
    PERFORM ckp.seal('S6-BAD', v_body);
    RAISE EXCEPTION 's6 FAIL: bad Task seal should have raised';
  EXCEPTION
    WHEN OTHERS THEN
      v_caught := SQLERRM;
  END;

  IF v_caught NOT LIKE '%MinCountConstraintComponent%' THEN
    RAISE EXCEPTION 's6 FAIL: bad seal raised but not the SHACL gate: %', v_caught;
  END IF;
END $$;

-- Rollback proof: S6-BAD must NOT be in ckp.instances.
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM ckp.instances WHERE id = 'S6-BAD';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 's6 FAIL: bad seal left % rows in ckp.instances', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM ckp.instances WHERE id = 'S6-OK';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 's6 FAIL: good seal did not land (rows=%)', v_count;
  END IF;
END $$;

\echo s6_seal_shacl_gate: PASS
