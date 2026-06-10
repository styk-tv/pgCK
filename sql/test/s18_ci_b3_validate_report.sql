-- s18_ci_b3_validate_report.sql — CI-B-3 (SPEC.ROADMAP.v3.9.CHECKLIST index 18).
--
-- The ValidationReport shape gate. ckp.validate_report surfaces the engine's full
-- sh:ValidationReport as { conforms, violations[] } — field-level diagnostics, not the
-- boolean-only ckp.validate (rc-07). Confirms: a conformant payload → conforms:true, no
-- violations; a payload that violates a SHACL constraint → conforms:false with a structured
-- violations[] array.
--
-- Run (booted by the smoke): psql … < s18_ci_b3_validate_report.sql

\set ON_ERROR_STOP 1

-- (a) a conformant affordance → conforms=true, zero violations.
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  rep jsonb;
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:aff:s18-ok> a ckp:Affordance ;
  ckp:inTopic "input.kernel.TestK.action.ok.read" ;
  ckp:plane "instance" .';
BEGIN
  rep := ckp.validate_report(ttl, v_core);
  IF (rep->>'conforms')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's18 FAIL: conformant affordance reported conforms=% (violations=%)',
      rep->>'conforms', rep->'violations';
  END IF;
  IF jsonb_array_length(rep->'violations') <> 0 THEN
    RAISE EXCEPTION 's18 FAIL: conformant affordance carried violations: %', rep->'violations';
  END IF;
END $$;

-- (b) a non-conformant affordance (missing required ckp:inTopic — AffordanceShape minCount 1)
--     → conforms=false WITH field-level violations[] (rc-07 closed: structured, not boolean).
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  rep jsonb;
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:aff:s18-bad> a ckp:Affordance ;
  ckp:plane "instance" .';   -- missing required ckp:inTopic
BEGIN
  rep := ckp.validate_report(ttl, v_core);
  IF (rep->>'conforms')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 's18 FAIL: affordance missing inTopic wrongly conformed: %', rep;
  END IF;
  IF jsonb_array_length(rep->'violations') < 1 THEN
    RAISE EXCEPTION 's18 FAIL: no field-level violations[] surfaced (rc-07 not closed): %', rep;
  END IF;
  IF jsonb_typeof(rep->'violations'->0) <> 'object' THEN
    RAISE EXCEPTION 's18 FAIL: violation[0] is not a structured object: %', rep->'violations'->0;
  END IF;
END $$;

\echo s18_ci_b3_validate_report: PASS
