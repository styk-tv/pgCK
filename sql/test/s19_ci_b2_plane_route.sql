-- s19_ci_b2_plane_route.sql — CI-B-2 (SPEC.ROADMAP.v3.9.CHECKLIST index 17).
--
-- Plane route + verb migration. Confirms: an instance.* verb routes to execution
-- (instance.create seals a Task); the legacy alias still works (task.create); the resolvers
-- map correctly; a governance-plane verb routes to the propose stub (never executes). web2's
-- legacy surface is unchanged — s15 (run earlier in the smoke) is the no-regression guard.
--
-- Run (booted + kernel loaded by the smoke): psql … < s19_ci_b2_plane_route.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- (a) instance.create routes (by payload) to the Task seal and succeeds for ck_participant.
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('instance.create',
      '{"task":{"target_kernel":"demo","title":"s19 via instance.create"}}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's19 FAIL: instance.create errored: %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's19 FAIL: instance.create not ok: %', res; END IF;
END $$;

-- (b) the legacy alias task.create still works (alias window — web2 unchanged).
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('task.create',
      '{"task":{"target_kernel":"demo","title":"s19 via task.create alias"}}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's19 FAIL: task.create alias errored: %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's19 FAIL: task.create alias not ok: %', res; END IF;
END $$;

-- (c) the resolvers map correctly.
DO $$
BEGIN
  IF ckp.verb_canon('task.create')   <> 'instance.create' THEN RAISE EXCEPTION 's19 FAIL: verb_canon(task.create) wrong'; END IF;
  IF ckp.verb_canon('kernel.create') <> 'instance.create' THEN RAISE EXCEPTION 's19 FAIL: verb_canon(kernel.create) wrong (CK.Lib.Js fix)'; END IF;
  IF ckp.verb_canon('snapshot.board') <> 'instance.snapshot' THEN RAISE EXCEPTION 's19 FAIL: verb_canon(snapshot.board) wrong'; END IF;
  IF ckp.verb_to_legacy('instance.update', '{}'::jsonb) <> 'task.update' THEN RAISE EXCEPTION 's19 FAIL: verb_to_legacy(instance.update) wrong'; END IF;
  IF ckp.verb_to_legacy('instance.create', '{"task":{}}'::jsonb) <> 'task.create' THEN RAISE EXCEPTION 's19 FAIL: verb_to_legacy(instance.create,task) wrong'; END IF;
END $$;

-- (d) a governance-plane verb is plane-rejected (the propose stub), NOT executed.
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('kernel.propose_change', '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's19 FAIL: governance verb errored (should return a typed stub): %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'false' OR res->>'error' <> 'governance_plane_unavailable' THEN
    RAISE EXCEPTION 's19 FAIL: governance verb not plane-rejected: %', res;
  END IF;
END $$;

\echo s19_ci_b2_plane_route: PASS
