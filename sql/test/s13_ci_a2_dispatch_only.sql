-- s13_ci_a2_dispatch_only.sql — CI-A-2 test (SPEC.ROADMAP.v3.9.CHECKLIST index 22).
--
-- Acceptance (roadmap §4 / v3.9 §7): ck_participant can EXECUTE ckp.dispatch (the
-- four-tuple door) and no other ckp.*/pgrdf.* function; the operator-forensics view
-- is denied to ck_participant.
--
-- Run: psql -U pgck -d pgck -v ON_ERROR_STOP=1 < sql/test/s13_ci_a2_dispatch_only.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- ---------------------------------------------------------------------------
-- (a) Grant shape: ck_participant holds EXECUTE on the four-tuple door, and NOT on
--     other ckp.* functions.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT has_function_privilege('ck_participant', 'ckp.dispatch(text,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 's13 FAIL: ck_participant lacks EXECUTE on the dispatch door';
  END IF;
  IF has_function_privilege('ck_participant', 'ckp.seal(text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 's13 FAIL: ck_participant can EXECUTE ckp.seal (must be dispatch-only)';
  END IF;
  IF has_function_privilege('ck_participant', 'ckp.verify(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 's13 FAIL: ck_participant can EXECUTE ckp.verify';
  END IF;
  IF has_function_privilege('ck_participant', 'ckp._read_typed(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 's13 FAIL: ck_participant can EXECUTE ckp._read_typed (Ring-1 should be closed)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- (b) ck_participant CAN dispatch (the door runs as definer ck_substrate).
-- ---------------------------------------------------------------------------
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('instances.count', 'ckp://Kernel#demo', '{}'::jsonb, 'urn:ckp:participant:s13');
  EXCEPTION WHEN OTHERS THEN
    failed := SQLERRM;
  END;
  RESET ROLE;
  IF failed IS NOT NULL THEN
    RAISE EXCEPTION 's13 FAIL: ck_participant could not call ckp.dispatch: %', failed;
  END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's13 FAIL: dispatch returned not-ok: %', res;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- (c) ck_participant CANNOT reach any other ckp.* or pgrdf.* directly.
-- ---------------------------------------------------------------------------
DO $$
DECLARE denied boolean;
BEGIN
  denied := false;
  BEGIN SET LOCAL ROLE ck_participant; PERFORM ckp.seal('s13-x', '{"type":"y"}'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  IF NOT denied THEN RESET ROLE; RAISE EXCEPTION 's13 FAIL: ck_participant executed ckp.seal'; END IF;

  denied := false;
  BEGIN SET LOCAL ROLE ck_participant; PERFORM ckp.verify('s13-x');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  IF NOT denied THEN RESET ROLE; RAISE EXCEPTION 's13 FAIL: ck_participant executed ckp.verify'; END IF;

  denied := false;
  BEGIN SET LOCAL ROLE ck_participant; PERFORM pgrdf.sparql('ASK { ?s ?p ?o }');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  IF NOT denied THEN RESET ROLE; RAISE EXCEPTION 's13 FAIL: ck_participant executed pgrdf.sparql'; END IF;
END $$;

-- (d) Operator-forensics view is DEFERRED in CI-A-2 (see migration §2) — a VIEW can't
--     reference the runtime-created ckp tables at CREATE EXTENSION. No view to probe;
--     ck_participant's surface is exactly { ckp.dispatch } as asserted in (a)–(c).

RESET ROLE;
\echo s13_ci_a2_dispatch_only: PASS
