-- s26_ci_d4_vote_quorum.sql — CI-D-4 (SPEC.ROADMAP.v3.9.CHECKLIST index 9).
--
-- kernel.vote seals a ckp:Vote about a pending Proposal and reports approve-count vs the
-- Proposal's sealed requiresQuorum. Confirms: the first approve is below quorum (1/2), the
-- second meets it (2/2); an invalid vote value and a vote about an unknown proposal are both
-- rejected (typed, no seal).
--
-- Run (booted + kernel loaded by the smoke): psql … < s26_ci_d4_vote_quorum.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
CREATE TEMP TABLE IF NOT EXISTS s26 (piri text);
TRUNCATE s26;

-- propose a change requiring 2 approvals.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.propose_change',
    '{"op":"set_quorum","about":"urn:ckp:demo/kernel/board","requires_quorum":2}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's26 FAIL: propose failed: %', res; END IF;
  INSERT INTO s26 VALUES (res->>'proposal_iri');
END $$;

-- (a) first approve → quorum NOT met (1 of 2).
DO $$
DECLARE res jsonb; piri text := (SELECT piri FROM s26);
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value', 'approve'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's26 FAIL: first vote not ok: %', res; END IF;
  IF (res->>'approvals')::int <> 1 THEN RAISE EXCEPTION 's26 FAIL: approvals=% (want 1)', res->>'approvals'; END IF;
  IF (res->>'quorum_met')::boolean IS NOT FALSE THEN RAISE EXCEPTION 's26 FAIL: quorum met too early: %', res; END IF;
END $$;

-- (b) second approve → quorum MET (2 of 2).
DO $$
DECLARE res jsonb; piri text := (SELECT piri FROM s26);
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value', 'approve'));
  RESET ROLE;
  IF (res->>'approvals')::int <> 2 THEN RAISE EXCEPTION 's26 FAIL: approvals=% (want 2)', res->>'approvals'; END IF;
  IF (res->>'quorum_met')::boolean IS NOT TRUE THEN RAISE EXCEPTION 's26 FAIL: quorum not met at 2: %', res; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's26 FAIL: vote not verified: %', res; END IF;
END $$;

-- (c) an invalid vote value is rejected (no seal).
DO $$
DECLARE res jsonb; piri text := (SELECT piri FROM s26);
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value', 'maybe'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_vote_value' THEN RAISE EXCEPTION 's26 FAIL: bad vote value not rejected: %', res; END IF;
END $$;

-- (d) a vote about an unknown proposal is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.vote', '{"about":"ckp://Proposal#nope","value":"approve"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'unknown_proposal' THEN RAISE EXCEPTION 's26 FAIL: unknown proposal not rejected: %', res; END IF;
END $$;

\echo s26_ci_d4_vote_quorum: PASS
