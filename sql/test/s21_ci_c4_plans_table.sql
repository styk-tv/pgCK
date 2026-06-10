-- s21_ci_c4_plans_table.sql — CI-C-4 (SPEC.ROADMAP.v3.9.CHECKLIST index 15).
--
-- The ckp.plans table — derived compiled-plan state keyed (kernel, verb, epoch). Confirms: a
-- plan row round-trips; the (kernel, verb, epoch) primary key rejects a duplicate; a different
-- epoch for the same (kernel, verb) coexists (epoch versioning — the basis for atomic
-- invalidation in CI-C-2).
--
-- Run (booted by the smoke): psql … < s21_ci_c4_plans_table.sql

\set ON_ERROR_STOP 1

-- (a) a plan row round-trips.
DO $$
DECLARE v_plan jsonb;
BEGIN
  INSERT INTO ckp.plans (kernel, verb, epoch, plan)
    VALUES ('pgCK', 'instance.query', 1,
      '{"kind":"query","statement":"SELECT id FROM ckp.instances WHERE kernel = $1","params":["kernel"]}'::jsonb);
  SELECT plan INTO v_plan FROM ckp.plans WHERE kernel='pgCK' AND verb='instance.query' AND epoch=1;
  IF v_plan->>'kind' <> 'query' THEN RAISE EXCEPTION 's21 FAIL: plan did not round-trip: %', v_plan; END IF;
  IF v_plan->'params'->>0 <> 'kernel' THEN RAISE EXCEPTION 's21 FAIL: plan params lost: %', v_plan; END IF;
END $$;

-- (b) uniqueness on (kernel, verb, epoch) is enforced.
DO $$
DECLARE v_dup boolean := false;
BEGIN
  BEGIN
    INSERT INTO ckp.plans (kernel, verb, epoch, plan) VALUES ('pgCK', 'instance.query', 1, '{"kind":"query"}'::jsonb);
  EXCEPTION WHEN unique_violation THEN v_dup := true; END;
  IF NOT v_dup THEN RAISE EXCEPTION 's21 FAIL: duplicate (kernel,verb,epoch) was NOT rejected'; END IF;
END $$;

-- (c) a different epoch for the same (kernel, verb) coexists (epoch versioning).
DO $$
BEGIN
  INSERT INTO ckp.plans (kernel, verb, epoch, plan) VALUES ('pgCK', 'instance.query', 2, '{"kind":"query","epoch":2}'::jsonb);
  IF (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK' AND verb='instance.query') <> 2 THEN
    RAISE EXCEPTION 's21 FAIL: epoch 2 plan not stored alongside epoch 1';
  END IF;
END $$;

\echo s21_ci_c4_plans_table: PASS
