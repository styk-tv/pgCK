-- s46_validation_report.sql — v0.5 roadmap T5: the full SHACL ValidationReport.
--
-- An adopter validates a Ship (crew_size : xsd:integer, required) and sees TYPED violations:
--   (1) a valid Ship CONFORMS — and (the ⟹ direction) it SEALS;
--   (2) a Ship MISSING the required crew_size → a cardinality (minCount) violation;
--   (3) crew_size:"twelve" (a string) → a DATATYPE violation (not just "missing").
--
-- Run (booted by the smoke): psql … < s46_validation_report.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s46-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle($ttl$
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
@prefix ship: <urn:ckp:s46-test/type/> .
@prefix p:    <urn:ckp:s46-test/prop/> .
ship:ShipShape a sh:NodeShape ;
  sh:targetClass ship:Ship ;
  sh:property [ sh:path p:crew_size ; sh:minCount 1 ; sh:datatype xsd:integer ] ;
  sh:property [ sh:path p:name      ; sh:datatype xsd:string ] .
$ttl$, g, 'urn:ckp:s46-test/kernel#');
  PERFORM pgrdf.materialize(g);
END $setup$;

SET ckp.project = 's46-test';

-- (1) a valid Ship CONFORMS, and (⟹) a conforming body SEALS.
DO $$
DECLARE res jsonb; cr jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.validate',
    '{"body":{"type":"urn:ckp:s46-test/type/Ship","crew_size":12,"name":"Endeavour"}}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's46 FAIL (1): validate not ok: %', res; END IF;
  IF (res->>'conforms') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's46 FAIL (1): valid Ship should conform: %', res; END IF;
  cr := ckp.dispatch('instance.create','{"type":"urn:ckp:s46-test/type/Ship","crew_size":12,"name":"Endeavour"}'::jsonb);
  RESET ROLE;
  IF (cr->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's46 FAIL (1): validate-conforms but seal rejected (validate ⟹ seal broken): %', cr; END IF;
END $$;

-- (2) a Ship MISSING the required crew_size → a cardinality violation.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.validate',
    '{"body":{"type":"urn:ckp:s46-test/type/Ship","name":"Skiff"}}'::jsonb);
  RESET ROLE;
  IF (res->>'conforms') IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 's46 FAIL (2): missing crew_size should NOT conform: %', res; END IF;
  IF jsonb_array_length(res->'violations') < 1 THEN RAISE EXCEPTION 's46 FAIL (2): expected a violation: %', res; END IF;
  IF (res->'violations')::text NOT LIKE '%MinCount%' AND (res->'violations')::text NOT LIKE '%crew_size%' THEN
    RAISE EXCEPTION 's46 FAIL (2): expected a cardinality/crew_size violation: %', res->'violations'; END IF;
END $$;

-- (3) crew_size:"twelve" (string) → a DATATYPE violation (the fuller report, not just minCount).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.validate',
    '{"body":{"type":"urn:ckp:s46-test/type/Ship","crew_size":"twelve","name":"Defiant"}}'::jsonb);
  RESET ROLE;
  IF (res->>'conforms') IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 's46 FAIL (3): crew_size string should NOT conform: %', res; END IF;
  IF (res->'violations')::text NOT LIKE '%Datatype%' THEN
    RAISE EXCEPTION 's46 FAIL (3): expected a DATATYPE violation: %', res->'violations'; END IF;
END $$;

\echo s46_validation_report: PASS
