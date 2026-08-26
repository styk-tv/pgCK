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

-- (b) WRITE verb as ck_participant — task.create seals AND IS JUDGED, and the
--     journey earns the comment (three states in one release, each measured):
--     * pre-0.6.34: the link projection validated against a never-seeded board
--       graph — vacuous conforms:true (pgRDF#134, resolved as ours).
--     * first fix attempt asserted the refusal as the pass — WRONG: measured,
--       the seal itself is judged by demo's OWN declared law (example.kernel.ttl
--       declares board/Task + board/shape/Task; the composed surface targets it;
--       M4 = urn:ckp:board/shape/Task). "No goal, no task" rules the ROOT;
--       a sovereign project declaring board vocabulary seals lawfully under it.
--     * final form: assert the seal AND the judgment — M4 present and naming
--       the project's own shape. Stronger than the 0.4.81 assertion (which
--       checked ok+verified only), weaker than nothing: a seal with M4 absent
--       FAILS here now.
DO $$
DECLARE res jsonb; failed text; m4 text;
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
  SELECT body->>'https://conceptkernel.org/ontology/v3.11/core#conformsToShape' INTO m4
    FROM ckp.instances WHERE id = res->>'id';
  IF m4 IS NULL THEN
    RAISE EXCEPTION 's15 FAIL (b): task sealed with M4 ABSENT — admitted, ledgered, judged by NOTHING. The zero-focus pass is live on the seal path.';
  END IF;
  IF m4 NOT LIKE '%board/shape/Task' THEN
    RAISE EXCEPTION 's15 FAIL (b): task judged by an unexpected shape %', m4;
  END IF;
  RAISE NOTICE 's15 (b) PASS — sealed AND judged: M4 = %', m4;
END $$;

-- (b2) negative control: a task missing its required title is refused in-envelope.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('task.create', '{"task":{"target_kernel":"demo"}}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') = 'true' THEN RAISE EXCEPTION 's15 FAIL (b2): titleless task SEALED: %', res; END IF;
  RAISE NOTICE 's15 (b2) PASS — titleless task refused: %', res->>'error';
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
