-- s23_ci_c2_epoch_invalidation.sql — CI-C-2 (SPEC.ROADMAP.v3.9.CHECKLIST index 13).
--
-- Epoch check + atomic invalidation (the F-H staleness fix). Confirms: bump_epoch advances the
-- kernel epoch AND recompiles plans at the new epoch AND clears the pgRDF plan cache in one txn;
-- plan_exec follows the current epoch; a missing plan at the current epoch is recompiled-then-
-- retried inside the call (no stale window).
--
-- Run (booted by the smoke): psql … < s23_ci_c2_epoch_invalidation.sql

\set ON_ERROR_STOP 1
SELECT ckp.compile_plans('pgCK');

-- (a) bump_epoch increments the epoch and recompiles at the new epoch (and clears pgRDF cache).
DO $$
DECLARE e0 int; e1 int;
BEGIN
  e0 := (SELECT epoch FROM ckp.kernel_epoch WHERE kernel='pgCK');
  e1 := ckp.bump_epoch('pgCK');   -- also PERFORMs pgrdf.plan_cache_clear() — errors here if unavailable
  IF e1 <> e0 + 1 THEN RAISE EXCEPTION 's23 FAIL: bump_epoch %→% (want +1)', e0, e1; END IF;
  IF (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK' AND epoch=e1) < 2 THEN
    RAISE EXCEPTION 's23 FAIL: no recompiled plans at new epoch %', e1;
  END IF;
END $$;

-- (b) plan_exec uses the NEW (current) epoch's plans.
INSERT INTO ckp.instances(id, body) VALUES ('urn:ckp:s23:t1', '{"rdfs:label":"S23"}'::jsonb)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body;
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.plan_exec('pgCK', 'instance.get', '{"id":"urn:ckp:s23:t1"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' OR jsonb_array_length(res->'rows') <> 1 THEN
    RAISE EXCEPTION 's23 FAIL: instance.get at bumped epoch failed: %', res;
  END IF;
  IF (res->>'epoch')::int <> (SELECT epoch FROM ckp.kernel_epoch WHERE kernel='pgCK') THEN
    RAISE EXCEPTION 's23 FAIL: plan_exec used a stale epoch: %', res;
  END IF;
END $$;

-- (c) recompile-then-retry: delete the current-epoch plans, plan_exec recovers in-call.
DO $$
DECLARE res jsonb; e int;
BEGIN
  e := (SELECT epoch FROM ckp.kernel_epoch WHERE kernel='pgCK');
  DELETE FROM ckp.plans WHERE kernel='pgCK' AND epoch=e;
  res := ckp.plan_exec('pgCK', 'instance.get', '{"id":"urn:ckp:s23:t1"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's23 FAIL: recompile-then-retry did not recover a deleted plan: %', res;
  END IF;
  IF (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK' AND epoch=e) < 2 THEN
    RAISE EXCEPTION 's23 FAIL: plans were not recompiled in-call';
  END IF;
END $$;

\echo s23_ci_c2_epoch_invalidation: PASS
