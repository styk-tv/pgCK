-- s43_declared_predicates.sql — v0.5 roadmap T2: the declared predicate set.
--
-- A kernel declares `part_of` as a predicate (a `sh:path` in its kernel graph), and:
--   (1) `instance.link` with the DECLARED predicate seals + materializes (reachable);
--   (2) `instance.reach` over the declared predicate traverses to the linked instance;
--   (3) THE KEYSTONE — an UNDECLARED predicate is rejected by BOTH link and reach, even when it
--       sits in the conceptkernel namespace (the declared set, not the namespace, is the gate).
--
-- Run (booted by the smoke): psql … < s43_declared_predicates.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- declare a kernel predicate `part_of` (a sh:path on a shape in the kernel graph).
DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s43-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle($ttl$
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix t:  <urn:ckp:s43-test/type/> .
@prefix r:  <urn:ckp:s43-test/rel/> .
t:NodeShape a sh:NodeShape ;
  sh:targetClass t:Node ;
  sh:property [ sh:path r:part_of ] .
$ttl$, g, 'urn:ckp:s43-test/kernel#');
  PERFORM pgrdf.materialize(g);
END $setup$;

SET ckp.project = 's43-test';

-- (1) link with the DECLARED predicate seals + materializes (reachable:true).
DO $$
DECLARE r1 jsonb; r2 jsonb; P text := 'urn:ckp:s43-test/rel/part_of';
BEGIN
  SET LOCAL ROLE ck_participant;
  r1 := ckp.dispatch('instance.link', jsonb_build_object('source','urn:s43:a','predicate',P,'target','urn:s43:b'));
  r2 := ckp.dispatch('instance.link', jsonb_build_object('source','urn:s43:b','predicate',P,'target','urn:s43:c'));
  RESET ROLE;
  IF (r1->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's43 FAIL (1): declared-predicate link rejected: %', r1; END IF;
  IF (r1->>'reachable') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's43 FAIL (1): link not materialized: %', r1; END IF;
  IF (r2->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's43 FAIL (1): second link rejected: %', r2; END IF;
END $$;

-- (2) reach over the DECLARED predicate traverses transitively (a reaches {b, c}).
DO $$
DECLARE res jsonb; P text := 'urn:ckp:s43-test/rel/part_of';
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', jsonb_build_object('from','urn:s43:a','via',P));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's43 FAIL (2): reach not ok: %', res; END IF;
  IF NOT (res->'reached' @> '["urn:s43:b"]'::jsonb) THEN RAISE EXCEPTION 's43 FAIL (2): direct target b not reached: %', res; END IF;
  IF NOT (res->'reached' @> '["urn:s43:c"]'::jsonb) THEN RAISE EXCEPTION 's43 FAIL (2): transitive target c not reached: %', res; END IF;
END $$;

-- (3a) THE KEYSTONE — an UNDECLARED predicate (in the conceptkernel namespace) is rejected by reach.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach',
    jsonb_build_object('from','urn:s43:a','via','https://conceptkernel.org/ontology/v3.8/core#link'));
  RESET ROLE;
  IF res->>'error' <> 'undeclared_predicate' THEN
    RAISE EXCEPTION 's43 FAIL (3a): a namespaced-but-UNDECLARED predicate was NOT rejected by reach (declared set is the gate, not the namespace): %', res; END IF;
END $$;

-- (3b) and the same undeclared predicate is rejected by link.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.link', jsonb_build_object(
    'source','urn:s43:a','predicate','https://conceptkernel.org/ontology/v3.8/core#link','target','urn:s43:d'));
  RESET ROLE;
  IF res->>'error' <> 'undeclared_predicate' THEN
    RAISE EXCEPTION 's43 FAIL (3b): undeclared predicate NOT rejected by link: %', res; END IF;
END $$;

\echo s43_declared_predicates: PASS
