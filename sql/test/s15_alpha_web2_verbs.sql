-- s15_alpha_web2_verbs.sql — Critical Isolation Alpha: web2 verbs work UNDER the floor.
--
-- Confirms the floor at the pgCK level: reads work UNDER it, the role wall holds, and
-- (since pgRDF 0.6.34) the legacy alpha write REFUSES instead of sealing vacuously. A
-- connection holding ONLY ckp.dispatch (the ck_participant capability) drives the reads,
-- while still being denied pgrdf.* and the ckp internals. (The full browser confirmation is
-- web2's own step, with the stripped CK.Lib.Js.)
--
-- Run (extension booted + kernel loaded by the smoke harness): psql … < s15_alpha_web2_verbs.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- ck_participant must hold EXECUTE on the web2 2-arg dispatch (the alpha grant).
DO $$
BEGIN
  IF NOT has_function_privilege('ck_participant', 'ckp.dispatch(text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 's15 FAIL: ck_participant lacks EXECUTE on the web2 dispatch';
  END IF;
END $$;

-- (a) READ verbs as ck_participant — snapshot.board + instances.count + kernels.list.
DO $$
DECLARE res jsonb; failed text; verb text;
  verbs text[] := ARRAY['snapshot.board','instances.count','kernels.list'];
BEGIN
  FOREACH verb IN ARRAY verbs LOOP
    failed := NULL;
    SET LOCAL ROLE ck_participant;
    BEGIN
      res := ckp.dispatch(verb, '{}'::jsonb);
    EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
    RESET ROLE;
    IF failed IS NOT NULL THEN RAISE EXCEPTION 's15 FAIL: web2 read verb % errored: %', verb, failed; END IF;
    IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's15 FAIL: web2 verb % not ok: %', verb, res; END IF;
  END LOOP;
END $$;

-- (b) WRITE verb as ck_participant — INVERTED at pgRDF 0.6.34, and the inversion is the
--     honest state, checked against SPEC.CKP.v3.12 rather than patched around:
--
--     This assertion used to demand task.create SEALS. It only ever could because the
--     alpha path validated against a shapes graph with no SHACL target, and the engine
--     answered a vacuous conforms:true — the exact defect class A4 names ("vacuity is a
--     finding") and P5 records as retired (task.*/goal.* emit v3.7 types no current
--     surface declares). pgRDF 0.6.34 now REFUSES the vacuous verdict outright:
--       "shapes graph … declares no SHACL target (0 triples). Nothing would be
--        selected, so a verdict would be vacuous …"
--     The engine is enforcing this repo's own doctrine, so the gate flips: the REFUSAL
--     is the pass. A task.create that seals again means the vacuous pass came back —
--     that is the regression this now catches. The floored-write-path proof moves to a
--     declared type; the alpha-path repair (validate against the composed surface, or
--     retire task.create) is tests/v312-tdd case 16 + FINAL-HANDOVER B.
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('task.create',
      '{"task":{"target_kernel":"demo","title":"s15 alpha task"}}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's15 FAIL: task.create errored (raised instead of refusing in-envelope): %', failed; END IF;
  IF (res->>'ok') = 'true' THEN
    RAISE EXCEPTION 's15 FAIL (b): task.create SEALED — the vacuous validation pass is back. Either the engine stopped refusing no-target shapes graphs (pgrdf < 0.6.34 semantics) or the alpha path found a surface that admits a v3.7 Task. Both are findings: %', res;
  END IF;
  IF res::text NOT ILIKE '%vacuous%' AND res::text NOT ILIKE '%no SHACL target%' THEN
    RAISE EXCEPTION 's15 FAIL (b): task.create refused for an UNSTATED reason (expected the vacuous-verdict refusal): %', res;
  END IF;
  RAISE NOTICE 's15 (b) PASS — dead verb refused, vacuity named, nothing sealed';
END $$;

-- (c) The floor still holds: ck_participant cannot reach pgrdf.* or the ckp internals directly.
DO $$
DECLARE denied boolean;
BEGIN
  denied := false;
  BEGIN SET LOCAL ROLE ck_participant; PERFORM pgrdf.sparql('ASK { ?s ?p ?o }');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  IF NOT denied THEN RESET ROLE; RAISE EXCEPTION 's15 FAIL: ck_participant reached pgrdf.sparql'; END IF;

  denied := false;
  BEGIN SET LOCAL ROLE ck_participant; PERFORM 1 FROM ckp.instances LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  IF NOT denied THEN RESET ROLE; RAISE EXCEPTION 's15 FAIL: ck_participant SELECTed ckp.instances'; END IF;
END $$;

RESET ROLE;
\echo s15_alpha_web2_verbs: PASS
