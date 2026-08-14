
-- 0.4.64: unattributed seals REFUSE (the anon mint is gone). A test names
-- its service identity explicitly — the sanctioned operator form.
SELECT set_config('ckp.requester','svc:smoke-suite',false);
-- CKB-5 acceptance: ckp.seal() on a Task body materialises exactly 3 link
-- quads into the project's board graph (a + part_of_goal + target_kernel).
-- Run with: psql -f sql/test/s5_seal_project_links.sql

SET ckp.project = 'ckb5-test';

DO $$
DECLARE
  v_g     bigint := pgrdf.add_graph('urn:ckp:ckb5-test/kernel/board');
  v_before bigint;
  v_after  bigint;
  v_body   jsonb := jsonb_build_object(
    'type', 'urn:ckp:board/Task',
    'urn:ckp:board/task_id', 'S5-T-0001',
    'urn:ckp:board/title', 's5 seal project_links',
    'urn:ckp:board/part_of_goal', 's5-goal',
    'urn:ckp:board/target_kernel', 'pgck',
    'urn:ckp:board/lifecycle_state', 'pending',
    'urn:ckp:board/priority', 1,
    'urn:ckp:board/queue_seq', 1,
    'urn:ckp:board/created_at', '2026-05-28T16:00:00Z'
  );
BEGIN
  PERFORM pgrdf.clear_graph(v_g);
  v_before := pgrdf.count_quads(v_g);
  PERFORM ckp.seal('S5-T-0001', v_body);
  v_after := pgrdf.count_quads(v_g);
  IF v_after - v_before <> 3 THEN
    RAISE EXCEPTION 's5_seal_project_links: expected +3 board quads, got +%', v_after - v_before;
  END IF;
END $$;

\echo s5_seal_project_links: PASS
