-- s25_ci_d5_propose_change.sql — CI-D-5 (SPEC.ROADMAP.v3.9.CHECKLIST index 10).
--
-- kernel.propose_change seals a ckp:Proposal{pending} via the governance plane. Confirms: a
-- well-formed proposal seals (instance pending + verified HMAC chain); an unknown op is rejected
-- with NO seal; an injection-shaped `about` is rejected by the field gate (so the shape-gate TTL
-- can never be injected). The change is DATA about the type, not yet the type.
--
-- Run (booted + kernel loaded by the smoke): psql … < s25_ci_d5_propose_change.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- (a) a well-formed proposal seals a Proposal{pending} through the governance plane.
DO $$
DECLARE res jsonb; failed text; pid text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp.dispatch('kernel.propose_change',
      '{"op":"add_property","about":"urn:ckp:demo/kernel/board","requires_quorum":2,"detail":{"prop":"ckp:foo"}}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's25 FAIL: propose_change errored: %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's25 FAIL: propose_change not ok: %', res; END IF;
  IF res->>'state' <> 'pending' THEN RAISE EXCEPTION 's25 FAIL: proposal not pending: %', res; END IF;
  pid := res->>'proposal';
  IF NOT EXISTS (
    SELECT 1 FROM ckp.instances
    WHERE id = pid AND body->>'https://conceptkernel.org/ontology/v3.8/core#proposalState' = 'pending'
  ) THEN RAISE EXCEPTION 's25 FAIL: Proposal instance not sealed pending: %', pid; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's25 FAIL: proposal HMAC chain not verified: %', res; END IF;
END $$;

-- (b) an unknown op is rejected — typed, with NO seal.
DO $$
DECLARE res jsonb; v_before bigint;
BEGIN
  v_before := (SELECT count(*) FROM ckp.instances);
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.propose_change', '{"op":"drop_table_haha","about":"urn:ckp:demo/kernel/board"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'unknown_proposal_op' THEN RAISE EXCEPTION 's25 FAIL: unknown op not rejected: %', res; END IF;
  IF (SELECT count(*) FROM ckp.instances) <> v_before THEN RAISE EXCEPTION 's25 FAIL: rejected proposal still sealed an instance'; END IF;
END $$;

-- (c) an injection-shaped `about` is rejected by the field gate (the shape-gate TTL stays safe).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.propose_change', jsonb_build_object('op','add_class','about','urn:x> . <evil> a <bad'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_about' THEN RAISE EXCEPTION 's25 FAIL: injection-shaped about not rejected: %', res; END IF;
END $$;

\echo s25_ci_d5_propose_change: PASS
