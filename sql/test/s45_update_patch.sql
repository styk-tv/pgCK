-- s45_update_patch.sql — v0.5 roadmap T4: generic per-declared-shape update patch.
--
-- An adopter patches a typed instance by its declared properties:
--   (1) patch a DECLARED field (crew_size) — re-seals, number preserved, name unchanged, re-verified;
--   (2) THE KEYSTONE — patching an UNDECLARED field is rejected (undeclared_patch_key);
--   (3) the legacy flat {id, …fields} form still routes to task.update (back-compat).
--
-- Run (booted by the smoke): psql … < s45_update_patch.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s45-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle($ttl$
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix ship: <urn:ckp:s45-test/type/> .
@prefix p:    <urn:ckp:s45-test/prop/> .
ship:ShipShape a sh:NodeShape ;
  sh:targetClass ship:Ship ;
  sh:property [ sh:path p:crew_size ; sh:minCount 1 ] ;
  sh:property [ sh:path p:name      ; sh:minCount 1 ] .
$ttl$, g, 'urn:ckp:s45-test/kernel#');
  PERFORM pgrdf.materialize(g);
END $setup$;

SET ckp.project = 's45-test';

DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create','{"type":"urn:ckp:s45-test/type/Ship","name":"Endeavour","crew_size":12}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's45 FAIL: create rejected: %', res; END IF;
  PERFORM set_config('s45.ship', res->>'id', false);
END $$;

-- (1) patch a DECLARED field — re-seals, number preserved, name unchanged, re-verified.
DO $$
DECLARE res jsonb; b jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.update',
    jsonb_build_object('id', current_setting('s45.ship'), 'patch', jsonb_build_object('crew_size', 20)));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's45 FAIL (1): patch rejected: %', res; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's45 FAIL (1): not re-verified: %', res; END IF;
  SELECT body INTO b FROM ckp.instances WHERE id = current_setting('s45.ship');
  IF (b->'urn:ckp:s45-test/prop/crew_size') IS DISTINCT FROM '20'::jsonb THEN
    RAISE EXCEPTION 's45 FAIL (1): crew_size not patched to number 20 (declared IRI, type-preserved): %', b; END IF;
  IF (b->>'urn:ckp:s45-test/prop/name') <> 'Endeavour' THEN
    RAISE EXCEPTION 's45 FAIL (1): name should be unchanged by the crew_size patch: %', b; END IF;
END $$;

-- (2) THE KEYSTONE: patching an UNDECLARED field is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.update',
    jsonb_build_object('id', current_setting('s45.ship'), 'patch', jsonb_build_object('warp_core','x')));
  RESET ROLE;
  IF res->>'error' <> 'undeclared_patch_key' THEN
    RAISE EXCEPTION 's45 FAIL (2): undeclared patch key NOT rejected: %', res; END IF;
END $$;

-- (3) the legacy flat {id, …fields} form still routes to task.update (back-compat).
DO $$
DECLARE r jsonb; res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  r := ckp.dispatch('instance.create','{"task":{"target_kernel":"s45","title":"orig"}}'::jsonb);
  res := ckp.dispatch('instance.update', jsonb_build_object('id', r->>'id', 'title', 'renamed'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's45 FAIL (3): legacy flat task.update broke: %', res; END IF;
END $$;

\echo s45_update_patch: PASS
