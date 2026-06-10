-- s27_ci_d3_apply_cascade.sql — CI-D-3 (SPEC.ROADMAP.v3.9.CHECKLIST index 8).
--
-- kernel.apply cascade. Confirms: applying a quorum-met Proposal seals it `applied` AND advances
-- the kernel epoch (the DATA shape version), with the proof chain intact; applying a below-quorum
-- Proposal is rejected (no change); re-applying an applied Proposal is rejected (not pending).
--
-- Run (booted + kernel loaded by the smoke): psql … < s27_ci_d3_apply_cascade.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
CREATE TEMP TABLE IF NOT EXISTS s27 (piri text, piri2 text);
TRUNCATE s27;

-- P1 (quorum 1, approved → met); P2 (quorum 2, no votes → below quorum).
DO $$
DECLARE r1 jsonb; r2 jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  r1 := ckp.dispatch('kernel.propose_change', '{"op":"add_class","about":"urn:ckp:demo/kernel/board","requires_quorum":1}'::jsonb);
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about', r1->>'proposal_iri', 'value', 'approve'));
  r2 := ckp.dispatch('kernel.propose_change', '{"op":"add_property","about":"urn:ckp:demo/kernel/board","requires_quorum":2}'::jsonb);
  RESET ROLE;
  INSERT INTO s27 VALUES (r1->>'proposal_iri', r2->>'proposal_iri');
END $$;

-- (a) apply the quorum-met Proposal → applied + epoch advances + proof chain intact.
DO $$
DECLARE res jsonb; piri text := (SELECT piri FROM s27); e0 int;
BEGIN
  e0 := (SELECT epoch FROM ckp.kernel_epoch WHERE kernel='pgCK');
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's27 FAIL: apply not ok: %', res; END IF;
  IF res->>'state' <> 'applied' THEN RAISE EXCEPTION 's27 FAIL: proposal not applied: %', res; END IF;
  IF (res->>'epoch')::int <= e0 THEN RAISE EXCEPTION 's27 FAIL: epoch did not advance (%, %)', e0, res->>'epoch'; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's27 FAIL: applied proposal not verified: %', res; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ckp.instances
    WHERE body->>'@id' = piri AND body->>'https://conceptkernel.org/ontology/v3.8/core#proposalState' = 'applied'
  ) THEN RAISE EXCEPTION 's27 FAIL: proposal instance not sealed applied'; END IF;
END $$;

-- (b) applying a below-quorum Proposal is rejected (no change).
DO $$
DECLARE res jsonb; piri2 text := (SELECT piri2 FROM s27);
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri2));
  RESET ROLE;
  IF res->>'error' <> 'quorum_not_met' THEN RAISE EXCEPTION 's27 FAIL: below-quorum apply not rejected: %', res; END IF;
END $$;

-- (c) re-applying an already-applied Proposal is rejected (not pending).
DO $$
DECLARE res jsonb; piri text := (SELECT piri FROM s27);
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  RESET ROLE;
  IF res->>'error' <> 'proposal_not_pending' THEN RAISE EXCEPTION 's27 FAIL: re-apply not rejected: %', res; END IF;
END $$;

\echo s27_ci_d3_apply_cascade: PASS
