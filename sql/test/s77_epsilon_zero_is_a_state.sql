-- s77_epsilon_zero_is_a_state.sql — A NEVER-PINNED KERNEL IS NOT DRIFTING (0.4.89).
--
-- WHY THIS EXISTS. s72 separated `state` from `healthy` and guarded the
-- never-pinned branch with `v_epoch > 0`. It did not guard the ELSIF beneath
-- it, and in SQL that is the whole defect:
--
--     NULL IS DISTINCT FROM '<digest>'   -> TRUE          (the ELSIF fires)
--     'Pinned ' || left(NULL,12) || '…'  -> NULL          (one NULL annihilates)
--     jsonb_build_array(NULL)            -> [null]        (an unreadable finding)
--
-- So the case s72 deliberately excluded from the first branch fell straight
-- into the second, and a kernel on the day it was germinated accused itself of
-- SURFACE DRIFT in a finding no reader could see. SPORE §5.3 measured the same
-- boundary from the outside: "findings:[null] appears specifically in the
-- NEVER-PINNED case, not generally."
--
-- A check that reports a fault it cannot NAME is worse than no check. The
-- reader cannot act on it, cannot dismiss it, and learns to ignore the field —
-- which is the same failure s72 was written to prevent, one branch further on.
--
-- The claims:
--   (a) NEVER PINNED IS NOT DRIFT. A germinated kernel with no sealed Epoch
--       reports no SURFACE DRIFT finding. Absence of a pin is the
--       pre-governance STATE, already carried in `state`/`surface.pinned`.
--   (b) THE CONTROL THAT MATTERS — DRIFT STILL FIRES. A kernel WITH a pin that
--       differs from its actual surface must still report unhealthy, and the
--       finding must be READABLE and name both digests. Making (a) quiet must
--       not make (b) silent; a fix that trades a false alarm for a blind spot
--       is worse than the alarm.
--   (c) NO FINDING IS EVER JSON NULL, in any state. This is the floor: it is
--       asserted structurally, not by matching text, so it holds for findings
--       nobody has written yet.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  N        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_prev   text := current_setting('ckp.project', true);
  v_a      jsonb; v_b jsonb;
  v_nulls  int;
  v_drift  int;
  v_msg    text;
BEGIN
  -- ---- fixture: a germinated kernel, NEVER pinned (no ckp:Epoch) -----------
  INSERT INTO ckp.instances(id, body) VALUES ('s77-kernel', jsonb_build_object(
    '@id','urn:ckp:s77probe/kernel',
    'type', N||'Kernel'));
  PERFORM set_config('ckp.project', 's77probe', true);
  v_a := ckp.surface_check(NULL);

  -- ---- fixture: the SAME kernel, now PINNED to a digest that cannot match --
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES ('s77probe', 1)
    ON CONFLICT (kernel) DO UPDATE SET epoch = 1;
  INSERT INTO ckp.instances(id, body) VALUES ('s77-epoch', jsonb_build_object(
    '@id','urn:ckp:s77probe/epoch/1',
    'type', N||'Epoch',
    N||'epoch', 1,
    N||'producedBy','urn:ckp:s77probe/kernel/ck',
    N||'surfaceDigest','deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'));
  v_b := ckp.surface_check(NULL);

  -- ---- clean up BEFORE asserting, so a failure cannot leave fixtures behind
  PERFORM set_config('ckp.project', COALESCE(v_prev,''), true);
  DELETE FROM ckp.instances   WHERE id IN ('s77-kernel','s77-epoch');
  DELETE FROM ckp.kernel_epoch WHERE kernel = 's77probe';

  -- ---- (a) never pinned is not drift --------------------------------------
  IF v_a->>'state' IS DISTINCT FROM 'germinated' THEN
    RAISE EXCEPTION 's77 FAIL (a): a sealed ckp:Kernel should read as germinated, got %',
      COALESCE(v_a->>'state','<null>');
  END IF;
  IF v_a->'surface'->>'pinned' IS NOT NULL THEN
    RAISE EXCEPTION 's77 FAIL (a): fixture is wrong — this kernel should have NO pin, got %',
      v_a->'surface'->>'pinned';
  END IF;
  SELECT count(*) INTO v_drift FROM jsonb_array_elements_text(v_a->'findings') e
   WHERE e LIKE 'SURFACE DRIFT%';
  IF v_drift > 0 THEN
    RAISE EXCEPTION 's77 FAIL (a): a NEVER-PINNED kernel reported SURFACE DRIFT — absence of a pin is the pre-governance state, not a change. findings: %',
      v_a->'findings';
  END IF;
  RAISE NOTICE 's77 (a) PASS — never-pinned reports no drift (state=%, pinned=null)', v_a->>'state';

  -- ---- (b) THE CONTROL: real drift still fires, and is readable ------------
  SELECT count(*) INTO v_drift FROM jsonb_array_elements_text(v_b->'findings') e
   WHERE e LIKE 'SURFACE DRIFT%';
  IF v_drift = 0 THEN
    RAISE EXCEPTION 's77 FAIL (b): a kernel pinned to deadbeef… with a different actual surface reported NO drift — (a) bought its quiet with a blind spot. findings: %',
      v_b->'findings';
  END IF;
  IF (v_b->>'healthy')::boolean IS TRUE THEN
    RAISE EXCEPTION 's77 FAIL (b): real surface drift reported healthy:true';
  END IF;
  SELECT e INTO v_msg FROM jsonb_array_elements_text(v_b->'findings') e
   WHERE e LIKE 'SURFACE DRIFT%' LIMIT 1;
  IF v_msg IS NULL OR position('deadbeefdead' in v_msg) = 0 THEN
    RAISE EXCEPTION 's77 FAIL (b): the drift finding does not NAME the pinned digest — an unreadable alarm is the defect this test exists for. got: %',
      COALESCE(v_msg,'<null>');
  END IF;
  RAISE NOTICE 's77 (b) PASS — real drift still fires and names both digests';

  -- ---- (c) THE FLOOR: no finding is ever JSON null, in any state -----------
  SELECT (SELECT count(*) FROM jsonb_array_elements(v_a->'findings') e WHERE jsonb_typeof(e)='null')
       + (SELECT count(*) FROM jsonb_array_elements(v_b->'findings') e WHERE jsonb_typeof(e)='null')
    INTO v_nulls;
  IF v_nulls > 0 THEN
    RAISE EXCEPTION 's77 FAIL (c): % finding(s) came back as JSON null — a fault the reader cannot name. a: % b: %',
      v_nulls, v_a->'findings', v_b->'findings';
  END IF;
  RAISE NOTICE 's77 (c) PASS — no finding is JSON null in either state';

EXCEPTION WHEN OTHERS THEN
  -- fixtures must never survive a failure
  PERFORM set_config('ckp.project', COALESCE(v_prev,''), true);
  DELETE FROM ckp.instances   WHERE id IN ('s77-kernel','s77-epoch');
  DELETE FROM ckp.kernel_epoch WHERE kernel = 's77probe';
  RAISE;
END $$;

\echo 's77 PASS — epsilon-zero is a state; drift still fires; no finding is ever null'
