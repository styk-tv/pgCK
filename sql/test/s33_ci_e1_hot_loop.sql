-- s33_ci_e1_hot_loop.sql — CI-E-1 (SPEC.ROADMAP.v3.9.CHECKLIST index 1) — the Track E flip, v0.4.0.
--
-- The capstone: the entity-linking hot loop runs end-to-end AS ck_participant — propose → vote →
-- apply → create → verify — through the floored dispatch, and ck_participant still holds exactly
-- EXECUTE ckp.dispatch (it cannot reach ckp.instances directly). "CKP v3.9 Critical Isolation enforced."
--
-- Run (booted + kernel loaded by the smoke): psql … < s33_ci_e1_hot_loop.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- (1) the hot loop, entirely as ck_participant.
DO $$
DECLARE r jsonb; piri text; cid text;
BEGIN
  SET LOCAL ROLE ck_participant;

  -- GOVERNANCE plane: propose → vote → apply (a quorum-1 type change).
  r := ckp.dispatch('kernel.propose_change', '{"op":"set_quorum","about":"urn:ckp:demo/kernel/board","requires_quorum":1}'::jsonb);
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's33 FAIL: propose: %', r; END IF;
  piri := r->>'proposal_iri';
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value', 'approve'));
  r := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF r->>'state' <> 'applied' THEN RAISE EXCEPTION 's33 FAIL: governance apply: %', r; END IF;

  -- INSTANCE plane: create a sealed instance, then verify its HMAC chain.
  r := ckp.dispatch('instance.create', '{"task":{"target_kernel":"demo","title":"hot-loop"}}'::jsonb);
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's33 FAIL: create: %', r; END IF;
  cid := r->>'id';
  r := ckp.dispatch('instance.verify', jsonb_build_object('id', cid));
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's33 FAIL: verify: %', r; END IF;

  RESET ROLE;
END $$;

-- (2) the participant STILL holds exactly EXECUTE ckp.dispatch — no direct table reach.
DO $$
DECLARE leaked text := NULL;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    PERFORM 1 FROM ckp.instances LIMIT 1;
    leaked := 'ckp.instances';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  IF leaked IS NOT NULL THEN RAISE EXCEPTION 's33 FAIL: ck_participant reached % directly — floor breached', leaked; END IF;
END $$;

\echo s33_ci_e1_hot_loop: PASS
