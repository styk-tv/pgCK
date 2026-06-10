-- s20_ci_b1_routing_authority.sql — CI-B-1 (SPEC.ROADMAP.v3.9.CHECKLIST index 16) — Track B flip.
--
-- The sealed registry is the SOLE routing authority. Confirms: an unregistered verb fails
-- typed with {error:'unknown_affordance'} (no fallthrough, zero payload evaluation); a
-- registered verb still resolves through the registry; a sealed delegation fact routes to
-- {delegate:true} (distinct from unknown_affordance — delegation is a fact, not an absence).
-- s15 + s19 (run earlier in the smoke) guard that every shipped web2 verb still resolves.
--
-- Run (booted + kernel loaded by the smoke): psql … < s20_ci_b1_routing_authority.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- (a) an unregistered verb fails typed with unknown_affordance (no fallthrough, zero eval).
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN res := ckp.dispatch('bogus.verb', '{"any":"payload"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's20 FAIL: unknown verb errored (should be typed): %', failed; END IF;
  IF res->>'error' <> 'unknown_affordance' THEN RAISE EXCEPTION 's20 FAIL: unknown verb not unknown_affordance: %', res; END IF;
END $$;

-- (b) a registered read verb still resolves through the registry (not falsely rejected).
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN res := ckp.dispatch('kernels.list', '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's20 FAIL: kernels.list errored: %', failed; END IF;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's20 FAIL: kernels.list not ok: %', res; END IF;
END $$;

-- (c) a sealed delegation fact routes to {delegate:true} (distinct from unknown_affordance).
DO $$
DECLARE res jsonb; failed text;
BEGIN
  INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane, delegate)
    VALUES ('pgCK','tool.example','input.kernel.pgCK.action.tool.example','instance', true)
    ON CONFLICT (kernel, verb) DO UPDATE SET delegate = true;
  SET LOCAL ROLE ck_participant;
  BEGIN res := ckp.dispatch('tool.example', '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN failed := SQLERRM; END;
  RESET ROLE;
  IF failed IS NOT NULL THEN RAISE EXCEPTION 's20 FAIL: delegate verb errored: %', failed; END IF;
  IF (res->>'delegate')::boolean IS NOT TRUE THEN RAISE EXCEPTION 's20 FAIL: delegate verb not delegate:true: %', res; END IF;
END $$;

\echo s20_ci_b1_routing_authority: PASS
