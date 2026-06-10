-- s15_alpha_web2_verbs.sql — Critical Isolation Alpha: web2 verbs work UNDER the floor.
--
-- Confirms the maintainer's question — "will web2 work fine with this release?" — at the
-- pgCK level: a connection holding ONLY ckp.dispatch (the ck_participant capability) can
-- drive web2's verb surface (reads AND a seal-backed write) through the floored dispatch,
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

-- (b) WRITE verb as ck_participant — task.create seals a governed Task through the floored
--     definer path (dispatch -> ckp.seal -> SHACL gate -> ledger -> proof, all as ck_substrate).
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('task.create',
      '{"task":{"target_kernel":"demo","title":"s15 alpha task"}}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's15 FAIL: task.create errored: %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's15 FAIL: task.create not ok: %', res; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's15 FAIL: task.create not verified: %', res; END IF;
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
