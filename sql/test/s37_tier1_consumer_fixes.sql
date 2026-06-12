-- s37_tier1_consumer_fixes.sql — Tier-1 fixes from CK.Lib.Js's npm-gate punch-list (0.4.3).
--
-- (b) instance.transition now works on a REAL task: it reads the v3.7 lifecycle_state task.create
--     writes (was reading v3.8 core# → always 'draft'), and the map covers planned→in_progress→done.
-- (c) concept.match finds a task by its title (was searching rdfs:label, which tasks don't carry → []).
-- (a) instance.validate is now HANDLED (was unknown/ungoverned); predicts the seal's required-props gate.
--
-- Run (booted by the smoke): psql … < s37_tier1_consumer_fixes.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- create a real task (lifecycle_state defaults to 'planned') with a unique title.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create', '{"task":{"target_kernel":"s37","title":"zqflow37 patrol"}}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's37 FAIL: create: %', res; END IF;
  PERFORM set_config('s37.tid', res->>'id', false);
END $$;

-- (b) transition planned → in_progress → done, and the task's OWN lifecycle field updates.
DO $$
DECLARE res jsonb; N text := 'https://conceptkernel.org/ontology/v3.7/'; tid text := current_setting('s37.tid');
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', tid, 'to_state','in_progress'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's37 FAIL (b): planned→in_progress rejected: %', res; END IF;
  IF res->>'from' <> 'planned' THEN RAISE EXCEPTION 's37 FAIL (b): gate saw from=% not planned (state-key still split)', res->>'from'; END IF;
  IF (SELECT body->>(N||'lifecycle_state') FROM ckp.instances WHERE id=tid) <> 'in_progress' THEN
    RAISE EXCEPTION 's37 FAIL (b): task lifecycle_state not updated to in_progress'; END IF;
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', tid, 'to_state','done'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's37 FAIL (b): in_progress→done rejected: %', res; END IF;
END $$;

-- (b-neg) an out-of-map transition is still rejected (planned→done not allowed directly).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create', '{"task":{"target_kernel":"s37","title":"zqflow37 b"}}'::jsonb);
  PERFORM set_config('s37.tid2', res->>'id', false);
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', current_setting('s37.tid2'), 'to_state','done'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_transition' THEN RAISE EXCEPTION 's37 FAIL (b-neg): planned→done not rejected: %', res; END IF;
END $$;

-- (c) concept.match finds the task by its title.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', '{"term":"zqflow37"}'::jsonb);
  RESET ROLE;
  IF (res->>'count')::int < 1 THEN RAISE EXCEPTION 's37 FAIL (c): concept.match found % for a title that exists (label-field fix)', res->>'count'; END IF;
END $$;

-- (a) instance.validate is handled (not unknown), and an unshaped type is valid silence → conforms.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.validate', '{"body":{"type":"urn:test:NoShape","x":1}}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's37 FAIL (a): validate not handled (unknown_affordance?): %', res; END IF;
  IF (res->>'conforms') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's37 FAIL (a): unshaped type should be valid silence: %', res; END IF;
END $$;

\echo s37_tier1_consumer_fixes: PASS
