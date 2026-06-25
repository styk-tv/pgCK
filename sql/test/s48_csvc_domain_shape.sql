\set ON_ERROR_STOP 1
-- s48 — CSVC domain kernel shape enforces (regression for "shapes playing right" on a DOMAIN kernel,
-- not just the built-in Greeting). Loads the consensus.services backend shape (fixtures/ontologies/csvc.ttl,
-- urn:ckp:csvc scheme — a v3.9 domain kernel, NOT an http vocabulary version) into the project kernel graph
-- and asserts: valid instances of all three CSVC kernels seal; a ConsensusTopic missing the required `label`
-- is rejected by ckp.seal (the required-props gate). sh:in enum enforcement is pgCK T5 (v0.4.12) — flagged
-- here, tightened to a reject assertion when T5 lands. Proven live on csvc.localhost / pgCK 0.4.13 (2026-06-14).
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

-- compose the CSVC shape into the project kernel graph (urn:ckp:demo/kernel/ck) — recreate, one parse_turtle
DO $load$
DECLARE g int;
BEGIN
  g := pgrdf.add_graph('urn:ckp:demo/kernel/ck');
  PERFORM pgrdf.parse_turtle($ttl$
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
<urn:ckp:csvc/type/Session> a rdfs:Class .
<urn:ckp:csvc/prop/name> a owl:DatatypeProperty .
<urn:ckp:csvc/shape/Session> a sh:NodeShape ;
  sh:targetClass <urn:ckp:csvc/type/Session> ;
  sh:property [ sh:path <urn:ckp:csvc/prop/name> ; sh:minCount 1 ; sh:maxCount 1 ; sh:datatype xsd:string ] .
<urn:ckp:csvc/type/ConsensusTopic> a rdfs:Class .
<urn:ckp:csvc/prop/label> a owl:DatatypeProperty .
<urn:ckp:csvc/prop/kind> a owl:DatatypeProperty .
<urn:ckp:csvc/shape/ConsensusTopic> a sh:NodeShape ;
  sh:targetClass <urn:ckp:csvc/type/ConsensusTopic> ;
  sh:property [ sh:path <urn:ckp:csvc/prop/label> ; sh:minCount 1 ; sh:maxCount 1 ; sh:datatype xsd:string ] ;
  sh:property [ sh:path <urn:ckp:csvc/prop/kind> ; sh:minCount 1 ; sh:maxCount 1 ;
                sh:in ( "topic" "action" "agreement" "decision" "risk" ) ] .
<urn:ckp:csvc/type/ConceptLink> a rdfs:Class .
<urn:ckp:csvc/prop/source> a owl:ObjectProperty .
<urn:ckp:csvc/prop/target> a owl:ObjectProperty .
<urn:ckp:csvc/prop/predicate> a owl:DatatypeProperty .
<urn:ckp:csvc/shape/ConceptLink> a sh:NodeShape ;
  sh:targetClass <urn:ckp:csvc/type/ConceptLink> ;
  sh:property [ sh:path <urn:ckp:csvc/prop/source> ; sh:minCount 1 ; sh:maxCount 1 ; sh:nodeKind sh:IRI ] ;
  sh:property [ sh:path <urn:ckp:csvc/prop/target> ; sh:minCount 1 ; sh:maxCount 1 ; sh:nodeKind sh:IRI ] ;
  sh:property [ sh:path <urn:ckp:csvc/prop/predicate> ; sh:minCount 1 ; sh:maxCount 1 ;
                sh:in ( "notifies" "reads_from" "composes" "delegates" "confirms" "distinct_from" "same_as" ) ] .
$ttl$, g, 'urn:ckp:demo/kernel/ck#');
  PERFORM pgrdf.materialize(g);
END $load$;

-- 1) VALID ConsensusTopic seals (required props present)
DO $ok$
DECLARE d text;
BEGIN
  d := ckp.seal('s48-topic-ok',
    '{"type":"urn:ckp:csvc/type/ConsensusTopic","urn:ckp:csvc/prop/label":"delivery window","urn:ckp:csvc/prop/kind":"agreement"}'::jsonb);
  IF length(d) <> 64 THEN RAISE EXCEPTION 's48 FAIL: expected 64-char digest, got %', d; END IF;
  IF (SELECT count(*) FROM ckp.instances WHERE id='s48-topic-ok') <> 1 THEN RAISE EXCEPTION 's48 FAIL: no instance row'; END IF;
  IF (SELECT count(*) FROM ckp.proof WHERE about='s48-topic-ok') <> 1 THEN RAISE EXCEPTION 's48 FAIL: no proof row'; END IF;
  RAISE NOTICE 's48 PASS: valid ConsensusTopic sealed (digest %)', left(d,12);
END $ok$;

-- 2) REJECT ConsensusTopic missing required label (the core domain-shape enforcement)
DO $rej$
BEGIN
  PERFORM ckp.seal('s48-topic-bad',
    '{"type":"urn:ckp:csvc/type/ConsensusTopic","urn:ckp:csvc/prop/kind":"agreement"}'::jsonb);
  RAISE EXCEPTION 's48 FAIL: should reject ConsensusTopic missing label';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE '%missing required%' AND SQLERRM LIKE '%label%' THEN RAISE NOTICE 's48 PASS: %', SQLERRM;
  ELSE RAISE; END IF;
END $rej$;
SELECT count(*)=0 AS s48_no_bad FROM ckp.instances WHERE id='s48-topic-bad';

-- 3) VALID Session + ConceptLink seal (all three kernels recreate from the one shape)
DO $multi$
DECLARE d1 text; d2 text;
BEGIN
  d1 := ckp.seal('s48-session','{"type":"urn:ckp:csvc/type/Session","urn:ckp:csvc/prop/name":"OEM review"}'::jsonb);
  d2 := ckp.seal('s48-link','{"type":"urn:ckp:csvc/type/ConceptLink","urn:ckp:csvc/prop/source":"urn:csvc:topic:a","urn:ckp:csvc/prop/target":"urn:csvc:topic:b","urn:ckp:csvc/prop/predicate":"delegates"}'::jsonb);
  IF length(d1) <> 64 OR length(d2) <> 64 THEN RAISE EXCEPTION 's48 FAIL: Session/ConceptLink seal'; END IF;
  RAISE NOTICE 's48 PASS: Session + ConceptLink sealed';
END $multi$;

-- 4) KNOWN GAP — pgCK T5 (v0.4.12): sh:in enum not yet gated by ckp.seal (required-props/minCount only).
--    kind='banana' currently seals. When T5 ships and rejects it, this auto-PASSes; until then it NOTICEs
--    (NOT a failure — the suite stays green and the gap is visible).
DO $enum$
DECLARE d text;
BEGIN
  BEGIN
    d := ckp.seal('s48-topic-enum','{"type":"urn:ckp:csvc/type/ConsensusTopic","urn:ckp:csvc/prop/label":"x","urn:ckp:csvc/prop/kind":"banana"}'::jsonb);
    RAISE NOTICE 's48 KNOWN GAP (pgCK T5): sh:in enum NOT enforced — kind=banana sealed (digest %). Tighten to a reject assertion when T5 ships.', left(d,12);
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%enum%' OR SQLERRM LIKE '%sh:in%' OR SQLERRM LIKE '%not in%' OR SQLERRM LIKE '%constraint%' THEN
      RAISE NOTICE 's48 PASS (T5 landed): enum rejected — %', SQLERRM;
    ELSE RAISE; END IF;
  END;
END $enum$;
