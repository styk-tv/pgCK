-- s65_structural_grounding.sql — THE STRUCTURAL PLANE (0.4.67, §5b alignment).
--
--   (1) CROSS-STORE ACCEPTANCE: ckp._structural_digest of this rig's own copy
--       of the v3.11 core reproduces the founding pin measured on the BENCH by
--       the client-side fleet tool — three independent loads, one digest. This
--       is the property the whole plane exists for, asserted against the
--       published 64-hex pin, not against ourselves.
--   (2) RELABELLING INVARIANCE + the negative control: one TTL parsed twice
--       (fresh blank labels each parse) digests structurally EQUAL; a
--       genuinely different structure digests DIFFERENT — the check can fail.
--   (3) DOCTRINE STAYS EXISTENTIAL-FREE: a governed add_class now projects a
--       NAMED NodeShape with NAMED property shapes — zero blank nodes land in
--       the kernel graph — and the epoch its apply seals carries
--       structuralDigest beside surfaceDigest.
--   (4) surface.grounding censuses the kernel's ground through the door: both
--       digest planes, existential census, counts.
--
-- Run (booted by the smoke): psql … < s65_structural_grounding.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's65-test';

-- (1) the founding pin, reproduced from THIS store's independent copy.
DO $$
DECLARE d text;
BEGIN
  d := ckp._structural_digest(pgrdf.add_graph('urn:ckp:core'));
  IF d <> '9a791c6c3d6d07cbeeefb33b677e66e2b643f22d844689501458c5765272282d' THEN
    RAISE EXCEPTION 's65 FAIL (1): core structural digest %… does not reproduce the founding pin 9a791c6c… — the algorithm drifted from the fleet''s', left(d,16);
  END IF;
END $$;

-- (2) relabelling invariance, with the control that can fail.
DO $$
DECLARE g1 bigint; g2 bigint; g3 bigint;
  t text := '<urn:s65:C> <http://www.w3.org/ns/shacl#property> [ <http://www.w3.org/ns/shacl#path> <urn:s65:p> ; <http://www.w3.org/ns/shacl#minCount> 1 ] .';
  t3 text := '<urn:s65:C> <http://www.w3.org/ns/shacl#property> [ <http://www.w3.org/ns/shacl#path> <urn:s65:OTHER> ; <http://www.w3.org/ns/shacl#minCount> 1 ] .';
BEGIN
  g1 := pgrdf.add_graph('urn:s65:g1'); PERFORM pgrdf.clear_graph(g1); PERFORM pgrdf.parse_turtle(t, g1, 'urn:s65#');
  g2 := pgrdf.add_graph('urn:s65:g2'); PERFORM pgrdf.clear_graph(g2); PERFORM pgrdf.parse_turtle(t, g2, 'urn:s65#');
  IF ckp._structural_digest(g1) <> ckp._structural_digest(g2) THEN
    RAISE EXCEPTION 's65 FAIL (2): the same TTL parsed twice diverges structurally — labels leaked into the digest'; END IF;
  g3 := pgrdf.add_graph('urn:s65:g3'); PERFORM pgrdf.clear_graph(g3); PERFORM pgrdf.parse_turtle(t3, g3, 'urn:s65#');
  IF ckp._structural_digest(g1) = ckp._structural_digest(g3) THEN
    RAISE EXCEPTION 's65 FAIL (2): genuinely different graphs collide — the negative control cannot fail, so nothing here is a check'; END IF;
END $$;

-- (3) governed add_class → named shapes only, and the epoch carries both planes.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; n int; e jsonb;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_class', 'about','urn:ckp:s65-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('class','urn:ckp:s65-test/type/Doc',
      'properties', jsonb_build_array(jsonb_build_object('path','urn:ckp:s65-test/prop/title','minCount',1)))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's65 FAIL (3): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's65 FAIL (3): vote rejected: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's65 FAIL (3): apply rejected: %', ap; END IF;

  -- the doctrine took ZERO blank nodes from the projection.
  SELECT count(*) INTO n
    FROM pgrdf._pgrdf_quads q
    JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
    JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
   WHERE q.graph_id = pgrdf.add_graph('urn:ckp:s65-test/kernel/ck')
     AND NOT q.is_inferred AND (s.term_type = 2 OR o.term_type = 2);
  IF n <> 0 THEN
    RAISE EXCEPTION 's65 FAIL (3): governed add_class left % blank-node triple(s) in the doctrine — the bracket emission is back', n; END IF;

  -- the NAMED NodeShape landed.
  SELECT count(*) INTO n FROM pgrdf.sparql(
    'SELECT ?s WHERE { GRAPH <urn:ckp:s65-test/kernel/ck> { ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/shacl#NodeShape> } }') j
   WHERE j->>'s' LIKE 'urn:ckp:s65-test/shape/%';
  IF n < 1 THEN RAISE EXCEPTION 's65 FAIL (3): no named NodeShape under urn:ckp:s65-test/shape/ after apply'; END IF;

  -- the epoch the apply sealed carries BOTH planes.
  SELECT body INTO e FROM ckp.instances
   WHERE id LIKE 'epoch-s65-test-%' ORDER BY ts_created DESC LIMIT 1;
  IF e IS NULL THEN RAISE EXCEPTION 's65 FAIL (3): no sealed epoch for s65-test'; END IF;
  IF NOT (e ? 'https://conceptkernel.org/ontology/v3.11/core#structuralDigest') THEN
    RAISE EXCEPTION 's65 FAIL (3): epoch seal lacks structuralDigest — the plane did not reach the emission'; END IF;
  IF (e->>'https://conceptkernel.org/ontology/v3.11/core#structuralDigest') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 's65 FAIL (3): structuralDigest is not 64 lowercase hex'; END IF;
END $$;

-- (4) the census, through the door.
DO $$
DECLARE res jsonb; g jsonb; n int := 0;
BEGIN
  res := ckp.dispatch('surface.grounding', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's65 FAIL (4): surface.grounding not ok: %', res; END IF;
  IF jsonb_array_length(res->'graphs') < 2 THEN
    RAISE EXCEPTION 's65 FAIL (4): expected at least composed + kernel graphs, got %', res->'graphs'; END IF;
  FOR g IN SELECT jsonb_array_elements(res->'graphs') LOOP
    n := n + 1;
    IF NOT (g ? 'structuralDigest') OR NOT (g ? 'copyDigest') OR NOT (g ? 'distinctBnodes') THEN
      RAISE EXCEPTION 's65 FAIL (4): census row % lacks a plane or the existential count: %', n, g; END IF;
  END LOOP;
END $$;

\echo s65_structural_grounding: PASS
