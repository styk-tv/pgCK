-- s84_epoch_rename_honest_stamp.sql — THE NAME SAYS IT DOES NOT TRACK (0.4.104).
--
-- KernelShape demanded ckp:epoch minCount 1, so germination stamped a counter
-- that went stale on the first apply and was drawn as live by every reader —
-- every sun on the board rendered e0. The cure: the germination moment is
-- ckp:germinatedAtEpoch (immutable by meaning, honest by name), ckp:epoch
-- survives only on an Epoch (where it names an immutable position), and the
-- emitter follows the LOADED law so an upgraded door running the old core
-- does not refuse itself on MinCount (the 0.4.88 G-1 class).
\set ON_ERROR_STOP 1

DO $$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  n int; r jsonb; body jsonb; d text; comp int; ok boolean;
BEGIN
  -- (a) the LOADED law no longer forces the stamp.
  SELECT count(*) INTO n FROM pgrdf.sparql(
    'PREFIX sh: <http://www.w3.org/ns/shacl#> PREFIX ckp: <'||C||'>
     SELECT ?b WHERE { GRAPH <urn:ckp:core> { ckp:KernelShape sh:property ?b . ?b sh:path ckp:epoch } }');
  IF n > 0 THEN
    RAISE EXCEPTION 's84 (a) FAIL — the loaded KernelShape still carries a ckp:epoch path: the law forces the stale stamp'; END IF;
  RAISE NOTICE 's84 (a) PASS — the loaded KernelShape carries no ckp:epoch path';

  -- (b) germinatedAtEpoch is DECLARED — the honest name exists in the law.
  SELECT count(*) INTO n FROM pgrdf.sparql(
    'PREFIX ckp: <'||C||'> SELECT ?o WHERE { GRAPH <urn:ckp:core> { ckp:germinatedAtEpoch ?p ?o } }');
  IF n = 0 THEN
    RAISE EXCEPTION 's84 (b) FAIL — germinatedAtEpoch undeclared: the rename has no law behind it'; END IF;
  RAISE NOTICE 's84 (b) PASS — germinatedAtEpoch declared in the loaded core';

  -- (c) a REAL germination stamps the honest name and not the retired one.
  PERFORM set_config('ckp.requester','svc:s84',true);
  r := ckp.germinate_kernel('s84probe','s84','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's84 (c) FIXTURE FAIL — germination refused: %', r; END IF;
  SELECT i.body INTO body FROM ckp.instances i
   WHERE i.body->>'@id'='urn:ckp:s84probe/kernel' AND i.body->>'type'=C||'Kernel'
   ORDER BY i.ts_created DESC LIMIT 1;
  IF body ? (C||'epoch') THEN
    RAISE EXCEPTION 's84 (c) FAIL — germination still stamps mutable ckp:epoch on the sealed Kernel'; END IF;
  IF NOT (body ? (C||'germinatedAtEpoch')) THEN
    RAISE EXCEPTION 's84 (c) FAIL — neither stamp: the germination moment is unrecorded'; END IF;
  RAISE NOTICE 's84 (c) PASS — germination stamps germinatedAtEpoch, not ckp:epoch';

  -- (d) ONE RULE, TWO CALLERS: the emitter reads the same law this file read.
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
   WHERE ns.nspname='ckp' AND p.proname='germinate_kernel' LIMIT 1;
  IF d NOT LIKE '%_law_forces_kernel_epoch%' THEN
    RAISE EXCEPTION 's84 (d) FAIL — germination does not consult the law reader: the emitter carries a private copy of the rule'; END IF;
  IF ckp._law_forces_kernel_epoch() THEN
    RAISE EXCEPTION 's84 (d) FAIL — the law reader says the loaded law forces ckp:epoch, but (a) measured otherwise: the two rules disagree'; END IF;
  RAISE NOTICE 's84 (d) PASS — the emitter consults the same law reader, and it agrees with the direct measurement';

  -- (e) CONTROL: a Kernel candidate with NO epoch of either spelling now
  -- CONFORMS — under the old law this was a MinCount refusal, so this line is
  -- what proves the shape half actually landed.
  comp := ckp._composed_shapes(ckp._project());
  ok := ckp.validate('@prefix ckp: <'||C||'> . @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    <urn:ckp:s84x/kernel> a ckp:Kernel ; rdfs:label "s84x" ;
      ckp:inProject <urn:ckp:project:s84x> ; ckp:transportSegment "s84x" ;
      ckp:hasOrgan <urn:ckp:s84x/organ/ck>, <urn:ckp:s84x/organ/tool>, <urn:ckp:s84x/organ/data> .', comp);
  IF NOT ok THEN
    RAISE EXCEPTION 's84 (e) FAIL — a Kernel with no epoch stamp still refuses: the old MinCount survives somewhere in the composed surface'; END IF;
  RAISE NOTICE 's84 (e) PASS — a Kernel carrying no epoch of either spelling conforms';
END $$;

\echo 's84 PASS — the law dropped the stale stamp, germination stamps the honest name, the emitter follows the loaded law'
