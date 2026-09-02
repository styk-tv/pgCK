-- s88_scope_and_orbit.sql — THE MISSING MIDDLE, AND THE CLOCK AS LAW (0.4.108).
--
-- C-5: a rule bound to a sealed ckp:Scope binds its member kernels and does
-- not bind others — membership read at seal time, so the set rebinds live.
-- C-10: the next crossing is computable by a third party from the sealed law
-- alone; no orbit refuses BY NAME; and 'draft' joins the proposalState closed
-- set because the tick may DRAFT only.
\set ON_ERROR_STOP 1

DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        a_msg text := ''; c_ok boolean := false; r jsonb; u jsonb; real_iri text;
        comp int; ok boolean; prev_proj text := current_setting('ckp.project', true);
BEGIN
  PERFORM set_config('ckp.requester','svc:s88',true);
  SELECT g.iri INTO real_iri FROM pgrdf._pgrdf_graphs g
   WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id=g.graph_id AND NOT q.is_inferred)
   ORDER BY g.graph_id LIMIT 1;

  -- (a) scope binding: member refused BY the scope-bound obligation, non-member lands.
  DELETE FROM ckp.instances WHERE id IN ('s88-scope','s88-x');
  DELETE FROM ckp.proof_obligations WHERE obligation='s88-adopts';
  INSERT INTO ckp.instances(id, body) VALUES
    ('s88-scope', jsonb_build_object('@id','ckp://Scope#s88','type',C||'Scope',
       'http://www.w3.org/2000/01/rdf-schema#label','s88',
       C||'includesKernel', jsonb_build_array('urn:ckp:s88a/kernel')));
  INSERT INTO ckp.proof_obligations(project, obligation, target_type, check_name, active)
  VALUES ('ckp://Scope#s88', 's88-adopts', C||'Adoption', 'adopts-resolves', true);
  PERFORM set_config('ckp.project','s88a',true);
  BEGIN
    PERFORM ckp.seal('s88-x', jsonb_build_object('@id','ckp://Adoption#s88-x','type',C||'Adoption',
      C||'adopts','urn:ckp:module:s88-nothing', C||'intoEpoch',to_jsonb(0),
      C||'sourceDigest',repeat('a',64), C||'intoProject','urn:ckp:s88a'));
  EXCEPTION WHEN OTHERS THEN a_msg := SQLERRM; END;
  PERFORM set_config('ckp.project','s88c',true);
  BEGIN
    PERFORM ckp.seal('s88-x', jsonb_build_object('@id','ckp://Adoption#s88-x','type',C||'Adoption',
      C||'adopts', real_iri, C||'intoEpoch',to_jsonb(0),
      C||'sourceDigest',repeat('c',64), C||'intoProject','urn:ckp:s88c'));
    c_ok := true;
  EXCEPTION WHEN OTHERS THEN c_ok := false; a_msg := a_msg||' | C: '||SQLERRM; END;
  DELETE FROM ckp.proof_obligations WHERE obligation='s88-adopts';
  DELETE FROM ckp.instances WHERE id IN ('s88-scope','s88-x');
  PERFORM set_config('ckp.project',COALESCE(prev_proj,''),true);
  IF position('adopts-resolves' in a_msg) = 0 THEN
    RAISE EXCEPTION 's88 (a) FAIL — the scope member was not refused by the scope-bound obligation: %', COALESCE(left(a_msg,100),'sealed clean'); END IF;
  IF NOT c_ok THEN
    RAISE EXCEPTION 's88 (a) FAIL — a NON-member was bound too: %', left(a_msg,150); END IF;
  RAISE NOTICE 's88 (a) PASS — the scope binds its member by name and leaves the non-member alone';

  -- (b) orbit: germinated kernel with NO law refuses BY NAME through the DOOR verb.
  r := ckp.germinate_kernel('s88orb','s88','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's88 (b) FIXTURE FAIL — germination refused: %', r; END IF;
  r := ckp._dispatch_route('orbit.next', jsonb_build_object('kernel','s88orb'));
  IF r->>'error' IS DISTINCT FROM 'no_orbit_declared' OR r->>'sqlstate' IS DISTINCT FROM '42704' THEN
    RAISE EXCEPTION 's88 (b) FAIL — no-law kernel got %/%, wanted no_orbit_declared/42704', COALESCE(r->>'error','ok'), COALESCE(r->>'sqlstate','-'); END IF;
  RAISE NOTICE 's88 (b) PASS — a kernel without orbit law refuses BY NAME through the routed verb';

  -- (c) law sealed, verb and hand computation agree; lead >= period refused by the LAW.
  u := ckp.update_typed(jsonb_build_object('id','urn:ckp:s88orb/kernel','patch', jsonb_build_object(
        C||'orbitPeriodSeconds', 300, C||'orbitLeadSeconds', 30, C||'orbitSeat', 2,
        C||'orbitAnchor','2026-09-01T00:00:00Z')));
  IF (u->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's88 (c) FAIL — the orbit law would not seal: %', u->>'error'; END IF;
  r := ckp._dispatch_route('orbit.next', jsonb_build_object('kernel','s88orb'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's88 (c) FAIL — declared law, refused verb: %', r->>'error'; END IF;
  IF (r->>'nextCrossing')::timestamptz IS DISTINCT FROM
     ('2026-09-01T00:00:00Z'::timestamptz + (GREATEST(ceil(EXTRACT(epoch FROM (now() - '2026-09-01T00:00:00Z'::timestamptz))/300),1)::bigint * 300) * interval '1 second') THEN
    RAISE EXCEPTION 's88 (c) FAIL — verb and independent recomputation disagree: %', r->>'nextCrossing'; END IF;
  u := ckp.update_typed(jsonb_build_object('id','urn:ckp:s88orb/kernel','patch', jsonb_build_object(
        C||'orbitLeadSeconds', 400)));
  IF (u->>'ok')::boolean IS TRUE THEN
    RAISE EXCEPTION 's88 (c) FAIL — a lead LONGER than the period sealed: the prepare window never closes and the law did not refuse it'; END IF;
  RAISE NOTICE 's88 (c) PASS — third-party recomputation agrees (%); lead >= period refused by the declared law', r->>'nextCrossing';

  -- (d) 'draft' is lawful and a bogus state still refuses — the closed set
  -- gained exactly one word.
  comp := ckp._composed_shapes(ckp._project());
  ok := ckp.validate('@prefix ckp: <'||C||'> . @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:s88/prop/1> a ckp:Proposal ; ckp:about <urn:ckp:s88orb/kernel/ck> ;
      ckp:proposalState "draft" ; ckp:proposalOp "add_class" ; ckp:requiresQuorum "2"^^xsd:integer .', comp);
  IF NOT ok THEN
    RAISE EXCEPTION 's88 (d) FAIL — a draft Proposal does not conform: the tick''s one permitted act is unlawful'; END IF;
  ok := ckp.validate('@prefix ckp: <'||C||'> . @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:s88/prop/2> a ckp:Proposal ; ckp:about <urn:ckp:s88orb/kernel/ck> ;
      ckp:proposalState "simmering" ; ckp:proposalOp "add_class" ; ckp:requiresQuorum "2"^^xsd:integer .', comp);
  IF ok THEN
    RAISE EXCEPTION 's88 (d) FAIL — a bogus proposalState conformed: the set opened, it did not grow by one word'; END IF;
  RAISE NOTICE 's88 (d) PASS — draft is lawful, the closed set still closes';
END $$;

\echo 's88 PASS — the scope binds its members only; the clock is law a third party can compute; the tick may draft'
