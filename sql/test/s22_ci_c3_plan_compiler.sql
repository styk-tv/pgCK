-- s22_ci_c3_plan_compiler.sql — CI-C-3 (SPEC.ROADMAP.v3.9.CHECKLIST index 14).
--
-- The apply-time plan compiler. Confirms: compile_plans stamps the sealed read templates into
-- ckp.plans at the kernel's current epoch; plan_exec resolves a plan and BINDS the caller's
-- value positionally (EXECUTE … USING) — a SQL-injection id is bound as a literal and matches
-- nothing (the table is NOT dumped); a no-param plan runs; recompile at the same epoch is
-- idempotent.
--
-- Run (booted by the smoke): psql … < s22_ci_c3_plan_compiler.sql

\set ON_ERROR_STOP 1

-- compile the sealed read templates at the kernel's current epoch.
DO $$
DECLARE n int;
BEGIN
  n := ckp.compile_plans('pgCK');
  IF n < 2 THEN RAISE EXCEPTION 's22 FAIL: compile_plans returned % (< 2)', n; END IF;
  IF (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK' AND verb IN ('instance.get','instance.count') AND epoch=1) <> 2 THEN
    RAISE EXCEPTION 's22 FAIL: expected 2 plans at epoch 1';
  END IF;
END $$;

-- a known instance to read back.
INSERT INTO ckp.instances(id, body) VALUES ('urn:ckp:s22:t1', '{"rdfs:label":"S22"}'::jsonb)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body;

-- (a) plan_exec binds the id param and returns the row.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.plan_exec('pgCK', 'instance.get', '{"id":"urn:ckp:s22:t1"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's22 FAIL: instance.get not ok: %', res; END IF;
  IF jsonb_array_length(res->'rows') <> 1 THEN RAISE EXCEPTION 's22 FAIL: instance.get returned % rows (want 1)', jsonb_array_length(res->'rows'); END IF;
  IF res->'rows'->0->'body'->>'rdfs:label' <> 'S22' THEN RAISE EXCEPTION 's22 FAIL: wrong row body: %', res; END IF;
END $$;

-- (b) a SQL-injection id is BOUND as a literal (never concatenated) → matches nothing.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.plan_exec('pgCK', 'instance.get', jsonb_build_object('id', 'x'' OR ''1''=''1'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's22 FAIL: injection probe errored: %', res; END IF;
  IF jsonb_array_length(res->'rows') <> 0 THEN
    RAISE EXCEPTION 's22 FAIL: injection id returned % rows — NOT parameter-bound (table dumped!)', jsonb_array_length(res->'rows');
  END IF;
END $$;

-- (c) a no-param plan executes (instance.count).
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.plan_exec('pgCK', 'instance.count', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's22 FAIL: instance.count not ok: %', res; END IF;
  IF (res->'rows'->0->>'n')::int < 1 THEN RAISE EXCEPTION 's22 FAIL: instance.count n < 1: %', res; END IF;
END $$;

-- (d) recompile at the same epoch is idempotent (no plan proliferation).
DO $$
DECLARE v_before int; v_after int;
BEGIN
  v_before := (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK');
  PERFORM ckp.compile_plans('pgCK');
  v_after := (SELECT count(*) FROM ckp.plans WHERE kernel='pgCK');
  IF v_after <> v_before THEN RAISE EXCEPTION 's22 FAIL: recompile changed plan count %→% (not idempotent)', v_before, v_after; END IF;
END $$;

\echo s22_ci_c3_plan_compiler: PASS
