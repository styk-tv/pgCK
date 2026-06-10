-- s28_ci_d2_fenced_rawttl.sql — CI-D-2 (SPEC.ROADMAP.v3.9.CHECKLIST index 7).
--
-- The fenced caller-Turtle path + materialization policy. Confirms: a valid ontology-extension
-- TTL parses + passes the meta-fence; instance data (a ckp:* data predicate) and a foreign
-- predicate are both fence-rejected; malformed Turtle fails in the parser (not our code); the
-- materialization policy admits valid trigger/profile and rejects invalid ones.
--
-- Run (booted by the smoke): psql … < s28_ci_d2_fenced_rawttl.sql

\set ON_ERROR_STOP 1

-- (a) a valid ontology-extension TTL stages + passes the fence (ontology-meta predicates only).
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.stage_ttl('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
@prefix owl: <http://www.w3.org/2002/07/owl#> .
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
ckp:fooProp a owl:DatatypeProperty ; rdfs:comment "a governed extension property" .
ckp:FooShape a sh:NodeShape ; sh:targetClass ckp:Foo ; sh:property [ sh:path ckp:fooProp ; sh:minCount 1 ] .');
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's28 FAIL: valid ontology TTL did not pass the fence: %', res; END IF;
END $$;

-- (b) instance data (a ckp:* DATA predicate) is fenced out — only ontology-meta is admitted.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.stage_ttl('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:sneaky> ckp:title "I am instance data, not ontology" .');
  IF res->>'error' <> 'fence_violation' THEN RAISE EXCEPTION 's28 FAIL: instance data not fenced: %', res; END IF;
END $$;

-- (c) a foreign-namespace predicate is fenced out.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.stage_ttl('@prefix ex: <http://evil.example/> .
<urn:ckp:x> ex:pwn "gotcha" .');
  IF res->>'error' <> 'fence_violation' THEN RAISE EXCEPTION 's28 FAIL: foreign predicate not fenced: %', res; END IF;
END $$;

-- (d) malformed Turtle fails in the parser (not our code) → parse_error.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.stage_ttl('this is not valid turtle <<< }}}');
  IF res->>'error' <> 'parse_error' THEN RAISE EXCEPTION 's28 FAIL: malformed TTL not a parse_error: %', res; END IF;
END $$;

-- (e) materialization policy: valid stored; invalid trigger/profile rejected.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.set_materialize_policy('{"trigger":"on_seal","profile":"rdfs"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's28 FAIL: valid policy rejected: %', res; END IF;
  res := ckp.set_materialize_policy('{"trigger":"yolo","profile":"rdfs"}'::jsonb);
  IF res->>'error' <> 'invalid_trigger' THEN RAISE EXCEPTION 's28 FAIL: invalid trigger not rejected: %', res; END IF;
  res := ckp.set_materialize_policy('{"trigger":"batch","profile":"sparql-magic"}'::jsonb);
  IF res->>'error' <> 'invalid_profile' THEN RAISE EXCEPTION 's28 FAIL: invalid profile not rejected: %', res; END IF;
END $$;

\echo s28_ci_d2_fenced_rawttl: PASS
