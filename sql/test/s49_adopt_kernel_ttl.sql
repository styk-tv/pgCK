-- s49_adopt_kernel_ttl.sql — v0.4.14 (#18): the authorized CK-loop writer restores enforcement.
--
-- ckp.adopt_kernel_ttl seals a type shape into urn:ckp:<proj>/kernel/ck — the graph the typed ops
-- + seal gate actually read — as a supported, file-mount-free bootstrap call (what oci-germination
-- asked for; they won't shim init.sql or hand-write /ck). #18 was that the documented bootstrap put
-- shapes in /board, leaving /ck unauthored so every gate no-ops. This asserts: (1) the shape lands in
-- /ck; (2) THROUGH THE DISPATCH DOOR as ck_participant, a create missing a required prop is REJECTED
-- (gate non-vacuous) and a complete one seals. Operator-level writer; ck_participant never writes /ck.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

DO $setup$ DECLARE g bigint; BEGIN g := pgrdf.add_graph('urn:ckp:s49-test/kernel/ck'); PERFORM pgrdf.clear_graph(g); END $setup$;
SET ckp.project = 's49-test';

-- (1) adopt a Widget shape (required `code`) into /ck via the SANCTIONED writer; assert it lands in /ck.
DO $adopt$
DECLARE r jsonb; n int;
BEGIN
  r := ckp.adopt_kernel_ttl($ttl$
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
<urn:ckp:s49-test/type/Widget> a rdfs:Class .
<urn:ckp:s49-test/prop/code> a owl:DatatypeProperty .
<urn:ckp:s49-test/shape/Widget> a sh:NodeShape ;
  sh:targetClass <urn:ckp:s49-test/type/Widget> ;
  sh:property [ sh:path <urn:ckp:s49-test/prop/code> ; sh:minCount 1 ; sh:datatype xsd:string ] .
$ttl$, 's49-test');
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's49 FAIL (1): adopt_kernel_ttl not ok: %', r; END IF;
  -- the shape is in /ck (the gate graph) — not /board — so the gate is NON-vacuous.
  SELECT count(*) INTO n FROM pgrdf.sparql($q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?c WHERE { GRAPH <urn:ckp:s49-test/kernel/ck> { ?s sh:targetClass ?c } }
  $q$) j;
  IF n < 1 THEN RAISE EXCEPTION 's49 FAIL (1): shape NOT in /ck after adopt — gate would be vacuous: %', r; END IF;
END $adopt$;

-- (2) THROUGH THE DOOR (ck_participant): complete Widget seals; one missing `code` is REJECTED.
DO $door$
DECLARE ok jsonb; bad jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  ok  := ckp.dispatch('instance.create', '{"type":"urn:ckp:s49-test/type/Widget","code":"W-1"}'::jsonb);
  bad := ckp.dispatch('instance.create', '{"type":"urn:ckp:s49-test/type/Widget"}'::jsonb);
  RESET ROLE;
  IF (ok->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's49 FAIL (2): complete Widget should seal: %', ok; END IF;
  IF (bad->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's49 FAIL (2): Widget missing required `code` should be REJECTED (the #18 gate, now non-vacuous): %', bad; END IF;
END $door$;

\echo s49_adopt_kernel_ttl: PASS
