-- s36_instance_update_patch.sql — instance.update partial-patch + JSON type fidelity.
-- Answers CK.Lib.Js NOTIFY instance-update-patch-gaps (2026-06-11):
--   2.1 — an update carrying both title + priority must apply BOTH (the old handler dropped title).
--   2.2 — a number priority must stay a number through write → seal → snapshot projection.
--
-- Run (booted by the smoke): psql … < s36_instance_update_patch.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- create a task via the governed verb (priority sent as a NUMBER).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create', '{"task":{"target_kernel":"s36","title":"orig","priority":5}}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's36 FAIL: create: %', res; END IF;
  PERFORM set_config('s36.tid', res->>'id', false);
END $$;

-- (2.1) update with BOTH title AND priority (number) AND lifecycle_state — all must apply.
DO $$
DECLARE res jsonb; b jsonb; N text := 'https://conceptkernel.org/ontology/v3.7/'; tid text := current_setting('s36.tid');
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.update', jsonb_build_object('id', tid, 'title','renamed', 'priority', 1, 'lifecycle_state','active'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's36 FAIL: update: %', res; END IF;
  SELECT body INTO b FROM ckp.instances WHERE id=tid;
  IF b->>(N||'title') <> 'renamed' THEN RAISE EXCEPTION 's36 FAIL (2.1): title patch DROPPED — got %', b->>(N||'title'); END IF;
  IF b->>(N||'lifecycle_state') <> 'active' THEN RAISE EXCEPTION 's36 FAIL: lifecycle_state not applied'; END IF;
  -- (2.2) priority must be a JSON NUMBER, not the string "1".
  IF jsonb_typeof(b->(N||'priority')) <> 'number' THEN
    RAISE EXCEPTION 's36 FAIL (2.2): priority is % not number (value %)', jsonb_typeof(b->(N||'priority')), b->(N||'priority'); END IF;
  IF (b->(N||'priority'))::text <> '1' THEN RAISE EXCEPTION 's36 FAIL: priority value % (want 1)', b->(N||'priority'); END IF;
END $$;

-- (2.2 projection) the board snapshot must surface priority as a NUMBER too.
DO $$
DECLARE res jsonb; tprio jsonb; tid text := current_setting('s36.tid');
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('snapshot.board', '{}'::jsonb);
  RESET ROLE;
  SELECT (t->'priority') INTO tprio FROM jsonb_array_elements(res->'tasks') t WHERE t->>'id'=tid;
  IF jsonb_typeof(tprio) <> 'number' THEN RAISE EXCEPTION 's36 FAIL (2.2 projection): board priority is % not number (%)', jsonb_typeof(tprio), tprio; END IF;
END $$;

-- a string priority from a different client is preserved AS a string (type fidelity both ways).
DO $$
DECLARE res jsonb; b jsonb; N text := 'https://conceptkernel.org/ontology/v3.7/'; tid text := current_setting('s36.tid');
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.update', jsonb_build_object('id', tid, 'priority', '3'));
  RESET ROLE;
  SELECT body INTO b FROM ckp.instances WHERE id=tid;
  IF jsonb_typeof(b->(N||'priority')) <> 'string' THEN RAISE EXCEPTION 's36 FAIL: string priority not preserved as string (got %)', jsonb_typeof(b->(N||'priority')); END IF;
END $$;

\echo s36_instance_update_patch: PASS
