-- s42_query_shape.sql — v0.5 roadmap T1: the derived QueryShape.
--
-- An adopter models a Ship with declared `crew_size` + `name`, and queries it:
--   (1) a query by a DECLARED key (short name) returns the matching ships (the short key is
--       resolved to its declared property IRI, which the sealed body actually stores);
--   (1b) `name` (a declared string key) resolves + matches;
--   (2) THE KEYSTONE — an UNDECLARED filter key on the shaped type is rejected;
--   (3) an UNSHAPED type keeps the regex fallback (short-key query works; injection key rejected).
--
-- Run (booted by the smoke): psql … < s42_query_shape.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- Ship shape declaring crew_size + name as queryable properties (no minCount → not required;
-- the QueryShape is the declared sh:property set, independent of the seal's required-props gate).
DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s42-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle($ttl$
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix ship: <urn:ckp:s42-test/type/> .
@prefix p:    <urn:ckp:s42-test/prop/> .
ship:ShipShape a sh:NodeShape ;
  sh:targetClass ship:Ship ;
  sh:property [ sh:path p:crew_size ] ;
  sh:property [ sh:path p:name ] .
$ttl$, g, 'urn:ckp:s42-test/kernel#');
  PERFORM pgrdf.materialize(g);
END $setup$;

SET ckp.project = 's42-test';

-- create three ships: crew_size 5, 12, 20.
DO $$
BEGIN
  SET LOCAL ROLE ck_participant;
  PERFORM ckp.dispatch('instance.create','{"type":"urn:ckp:s42-test/type/Ship","name":"Skiff","crew_size":5}'::jsonb);
  PERFORM ckp.dispatch('instance.create','{"type":"urn:ckp:s42-test/type/Ship","name":"Cutter","crew_size":12}'::jsonb);
  PERFORM ckp.dispatch('instance.create','{"type":"urn:ckp:s42-test/type/Ship","name":"Frigate","crew_size":20}'::jsonb);
  RESET ROLE;
END $$;

-- (1) query by a DECLARED numeric key (short name) — resolved to the declared IRI, returns matches.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query',
    '{"type":"urn:ckp:s42-test/type/Ship","filter":[{"key":"crew_size","op":"gte","value":"10"}]}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's42 FAIL (1): query rejected: %', res; END IF;
  IF (res->>'shaped') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's42 FAIL (1): Ship should be shaped: %', res; END IF;
  IF (res->>'count')::int <> 2 THEN
    RAISE EXCEPTION 's42 FAIL (1): crew_size>=10 should match 2 (Cutter,Frigate), got %: %', res->>'count', res; END IF;
END $$;

-- (1b) a declared STRING key resolves + matches.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query',
    '{"type":"urn:ckp:s42-test/type/Ship","filter":[{"key":"name","op":"eq","value":"Frigate"}]}'::jsonb);
  RESET ROLE;
  IF (res->>'count')::int <> 1 THEN
    RAISE EXCEPTION 's42 FAIL (1b): name=Frigate should match 1 (declared key resolved to its IRI): %', res; END IF;
END $$;

-- (2) THE KEYSTONE: an UNDECLARED filter key on a shaped type is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query',
    '{"type":"urn:ckp:s42-test/type/Ship","filter":[{"key":"warp_core","op":"eq","value":"x"}]}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'undeclared_filter_key' THEN
    RAISE EXCEPTION 's42 FAIL (2): undeclared key warp_core NOT rejected on a shaped type: %', res; END IF;
END $$;

-- (3) an UNSHAPED type keeps the regex fallback — short-key query works; injection key rejected.
DO $$
DECLARE res jsonb;
BEGIN
  INSERT INTO ckp.instances(id, body)
    VALUES ('urn:s42:e1', '{"type":"urn:s42:Unshaped","color":"red"}'::jsonb)
    ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body;
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query',
    '{"type":"urn:s42:Unshaped","filter":[{"key":"color","op":"eq","value":"red"}]}'::jsonb);
  IF (res->>'shaped') IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 's42 FAIL (3): unshaped type should be shaped:false: %', res; END IF;
  IF (res->>'count')::int <> 1 THEN RAISE EXCEPTION 's42 FAIL (3): unshaped short-key query should match 1: %', res; END IF;
  res := ckp.dispatch('instance.query', jsonb_build_object('type','urn:s42:Unshaped',
           'filter', jsonb_build_array(jsonb_build_object('key','color OR 1=1','op','eq','value','y'))));
  RESET ROLE;
  IF res->>'error' <> 'invalid_filter_key' THEN
    RAISE EXCEPTION 's42 FAIL (3): injection key on unshaped type not rejected: %', res; END IF;
END $$;

\echo s42_query_shape: PASS
