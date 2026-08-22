-- s72_state_is_not_health.sql — A BRAND-NEW DATABASE IS NOT BROKEN (0.4.81).
--
-- WHY THIS EXISTS. surface.check reported `healthy:false` on a correctly
-- installed, brand-new database — with the finding "kernel graph … is EMPTY …
-- This is the 2026-08-10 wipe signature." Measured on a fresh ck-allinone:
-- nothing had ever been wiped, because nothing had ever existed. The check
-- could not tell NEVER EXISTED from WAS DESTROYED.
--
-- That is the twin of a check that can never fail: one that is false on every
-- correct day-one install trains its reader to ignore it, and then it cannot do
-- its job on the day something really is gone. sporaxis filed the adjacent half
-- (an ABSENT surface pin reported as drift, shipped with no fix text).
--
-- The fix separates two questions the field conflated:
--   state   core-only | named | germinated   — where you are in the lifecycle
--   healthy is THIS state internally consistent
--
-- The claims:
--   (a) CORE-ONLY IS HEALTHY. No kernel named: the surface IS core, the law is
--       readable, sealing refuses on M2. Nothing is missing that ought to be
--       there, so nothing is reported.
--   (b) THE WIPE DETECTOR SURVIVES — the control that matters. A GERMINATED
--       kernel whose graph is empty must STILL report unhealthy, naming the
--       wipe. Making (a) healthy must not blind (b); a fix that trades a false
--       alarm for a blind spot is worse than the alarm.
--   (c) A CURIE IS REFUSED, not answered. surface.declared/typecheck/explain
--       returned `declared:{}` / `admitted:false` for `ckp:Project` — a
--       confident absence about a type the gate judges daily, which a caller
--       cannot distinguish from a real one.
--   (d) CONTROL FOR (c): the SAME type as an absolute IRI still answers, so the
--       guard refuses prefixes rather than refusing everything.
\set ON_ERROR_STOP 1

-- (a) core-only is a complete state
DO $$
DECLARE v_prev text := current_setting('ckp.project', true); v_r jsonb;
BEGIN
  PERFORM set_config('ckp.project', '', true);
  v_r := ckp.surface_check(NULL);
  PERFORM set_config('ckp.project', COALESCE(v_prev,''), true);

  IF v_r->>'state' IS DISTINCT FROM 'core-only' THEN
    RAISE EXCEPTION 's72 FAIL (a): with no kernel named, state should be core-only, got %', COALESCE(v_r->>'state','<null>');
  END IF;
  IF (v_r->>'healthy')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's72 FAIL (a): core-only reported UNHEALTHY — a correctly installed brand-new database accusing itself. findings: %', v_r->'findings';
  END IF;
  RAISE NOTICE 's72 (a) PASS — core-only is healthy: %', v_r->>'note';
END $$;

-- (b) THE CONTROL: a germinated kernel with an empty graph is still a wipe.
-- Runs entirely inside a subtransaction that is rolled back, so no seal, no
-- graph and no epoch of this store is disturbed.
DO $$
DECLARE v_prev text := current_setting('ckp.project', true); v_r jsonb; v_caught boolean := false;
BEGIN
  BEGIN
    -- a sealed ckp:Kernel for a project whose kernel graph is empty == a wipe
    INSERT INTO ckp.instances(id, body) VALUES ('s72-probe', jsonb_build_object(
      '@id','urn:ckp:s72probe/kernel',
      'type','https://conceptkernel.org/ontology/v3.11/core#Kernel'));
    PERFORM set_config('ckp.project', 's72probe', true);
    v_r := ckp.surface_check(NULL);

    IF v_r->>'state' IS DISTINCT FROM 'germinated' THEN
      RAISE EXCEPTION 's72 FAIL (b): a sealed ckp:Kernel should read as germinated, got %', COALESCE(v_r->>'state','<null>');
    END IF;
    IF (v_r->>'healthy')::boolean IS TRUE THEN
      RAISE EXCEPTION 's72 FAIL (b): a GERMINATED kernel with an EMPTY graph reported healthy — the wipe detector is blind, and (a) bought that blindness.';
    END IF;
    IF position('wipe signature' in v_r->>'findings') = 0 THEN
      RAISE EXCEPTION 's72 FAIL (b): unhealthy, but the finding does not name the wipe: %', v_r->'findings';
    END IF;
    v_caught := true;
    RAISE EXCEPTION 's72-rollback';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('ckp.project', COALESCE(v_prev,''), true);
    IF SQLERRM <> 's72-rollback' THEN RAISE; END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 's72 FAIL (b): the control did not run';
  END IF;
  RAISE NOTICE 's72 (b) PASS — a germinated kernel with an empty graph still reports the wipe';
END $$;

-- (c) + (d) a CURIE is refused; the same type as an IRI still answers
DO $$
DECLARE v_curie jsonb; v_iri jsonb;
BEGIN
  v_curie := ckp.surface_declared(jsonb_build_object('type','ckp:Project'));
  IF COALESCE((v_curie->>'ok')::boolean, true) IS TRUE THEN
    RAISE EXCEPTION 's72 FAIL (c): surface.declared ANSWERED for the CURIE ckp:Project (%) instead of refusing — a confident absence about a type the gate judges daily.', v_curie;
  END IF;
  IF v_curie->>'error' IS DISTINCT FROM 'type_is_a_curie' THEN
    RAISE EXCEPTION 's72 FAIL (c): refused, but not as a CURIE: %', v_curie->>'error';
  END IF;

  v_iri := ckp.surface_declared(jsonb_build_object(
    'type','https://conceptkernel.org/ontology/v3.11/core#Project'));
  IF COALESCE((v_iri->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 's72 FAIL (d): the absolute IRI was ALSO refused — the guard refuses everything, not prefixes: %', v_iri;
  END IF;
  IF v_iri->'declared' = '{}'::jsonb THEN
    RAISE EXCEPTION 's72 FAIL (d): the IRI answered with an EMPTY contract — core#Project declares projectKind/ownedBy/label, so this is the vacuous answer wearing a different hat.';
  END IF;
  RAISE NOTICE 's72 (c)(d) PASS — CURIE refused, IRI answers with % declared propert(ies)',
    (SELECT count(*) FROM jsonb_object_keys(v_iri->'declared'));
END $$;

SELECT 's72_state_is_not_health: PASS';
