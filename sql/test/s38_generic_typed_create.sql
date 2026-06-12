-- s38_generic_typed_create.sql — Tier 2 (1/3): the adoption keystone.
--
-- An ADOPTER models a NON-Task type (a Ship with a required crew_size) and exercises
-- the generic typed `instance.create` against it. This is the exit test that flips
-- instance.create from a Task/Goal concretion to the §4 generic capability:
--   (1) a Ship WITH its required props seals + verifies;
--   (1b) the sealed body carries the type's DECLARED property IRIs (not bare keys);
--   (2) THE KEYSTONE — a Ship MISSING a required prop is REJECTED by the seal gate;
--   (3) instance.validate predicts the same gate (validate ⟺ seal) for the new type;
--   (4) the legacy {task:…} form still routes to task.create (back-compat intact).
--
-- Run (booted by the smoke): psql … < s38_generic_typed_create.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- Adopter declares a Ship shape directly in THIS project's kernel/ck graph — the same
-- graph ckp.seal gates required props on. (Tier 2 #34 will let governance.apply write
-- this same shape via consensus; here the adopter loads it as a fixture.)
DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s38-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle($ttl$
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix ship: <urn:ckp:s38-test/type/> .
@prefix p:    <urn:ckp:s38-test/prop/> .
ship:ShipShape a sh:NodeShape ;
  sh:targetClass ship:Ship ;
  sh:property [ sh:path p:crew_size ; sh:minCount 1 ] ;
  sh:property [ sh:path p:name      ; sh:minCount 1 ] .
$ttl$, g, 'urn:ckp:s38-test/kernel#');
  PERFORM pgrdf.materialize(g);
END $setup$;

SET ckp.project = 's38-test';

-- (1) generic create WITH both required props seals + verifies.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:s38-test/type/Ship","crew_size":12,"name":"Endeavour"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's38 FAIL (1): generic Ship create rejected: %', res; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's38 FAIL (1): Ship sealed but not verified: %', res; END IF;
  IF (res->>'type') <> 'urn:ckp:s38-test/type/Ship' THEN
    RAISE EXCEPTION 's38 FAIL (1): reply did not echo the type: %', res; END IF;
  PERFORM set_config('s38.ship', res->>'id', false);
END $$;

-- (1b) the sealed body maps caller fields to the type's DECLARED property IRIs,
--      preserving number types, and stores the type.
DO $$
DECLARE b jsonb;
BEGIN
  SELECT body INTO b FROM ckp.instances WHERE id = current_setting('s38.ship');
  IF b IS NULL THEN RAISE EXCEPTION 's38 FAIL (1b): no sealed Ship body found'; END IF;
  IF (b->'urn:ckp:s38-test/prop/crew_size') IS DISTINCT FROM '12'::jsonb THEN
    RAISE EXCEPTION 's38 FAIL (1b): crew_size not mapped to its declared IRI as a number: %', b; END IF;
  IF (b->>'urn:ckp:s38-test/prop/name') <> 'Endeavour' THEN
    RAISE EXCEPTION 's38 FAIL (1b): name not mapped to its declared IRI: %', b; END IF;
  IF (b->>'type') <> 'urn:ckp:s38-test/type/Ship' THEN
    RAISE EXCEPTION 's38 FAIL (1b): type not stored on the body: %', b; END IF;
END $$;

-- (2) THE KEYSTONE: a Ship MISSING the required crew_size is REJECTED by the gate
--     (the seal's required-props SPARQL over urn:ckp:s38-test/kernel/ck).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:s38-test/type/Ship","name":"Defiant"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's38 FAIL (2): Ship missing required crew_size was NOT rejected: %', res; END IF;
  IF res->>'error' NOT LIKE '%required%' AND res->>'error' NOT LIKE '%kernel shape%' THEN
    RAISE EXCEPTION 's38 FAIL (2): rejected, but not for the shape reason: %', res; END IF;
  -- and nothing leaked into the store for the rejected create.
  IF EXISTS (SELECT 1 FROM ckp.instances WHERE body->>'type'='urn:ckp:s38-test/type/Ship'
                                           AND body->>'urn:ckp:s38-test/prop/name'='Defiant') THEN
    RAISE EXCEPTION 's38 FAIL (2): a rejected create still left a row'; END IF;
END $$;

-- (3) instance.validate predicts the same gate for the generic type (validate ⟺ seal).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.validate',
    '{"body":{"type":"urn:ckp:s38-test/type/Ship","urn:ckp:s38-test/prop/name":"x"}}'::jsonb);
  RESET ROLE;
  IF (res->>'conforms') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's38 FAIL (3): validate should report non-conformance (missing crew_size): %', res; END IF;
END $$;

-- (4) the legacy {task:…} payload-key form STILL routes to task.create (back-compat).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"task":{"target_kernel":"s38","title":"legacy still works"}}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's38 FAIL (4): legacy {task} create broke: %', res; END IF;
  IF (res->>'id') NOT LIKE 'task-%' THEN
    RAISE EXCEPTION 's38 FAIL (4): legacy {task} did not route to task.create: %', res; END IF;
END $$;

\echo s38_generic_typed_create: PASS
