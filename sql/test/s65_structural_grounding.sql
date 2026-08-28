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

-- (1) the founding pin, reproduced from THIS store's independent copy — PER ROOT.
--     0.4.82: the boot default moved to v3.12 FINAL, so the loaded core may be
--     either line. A pin check that names one root misreports a CONTENT change
--     as ALGORITHM drift (measured on the first v3.12-booted run: 6e38f7bb… vs
--     the v3.11 pin, wrongly blamed on the algorithm). Detect the loaded root by
--     its shape arithmetic (27 = v3.11 · 30 = v3.12, both predicted-then-counted
--     founding numbers) and assert the MATCHING pin; an unknown count is its own
--     failure. Algorithm conformance against fixed content stays covered by s73
--     (module fixtures) and check (2)'s relabelling invariance below.
DO $$
DECLARE d text; n int;
BEGIN
  d := ckp._structural_digest(pgrdf.add_graph('urn:ckp:core'));
  SELECT count(*) INTO n FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF n = 27 THEN     -- v3.11 line
    IF d <> '9a791c6c3d6d07cbeeefb33b677e66e2b643f22d844689501458c5765272282d' THEN
      RAISE EXCEPTION 's65 FAIL (1): v3.11 core (27 shapes) digest %… does not reproduce the founding pin 9a791c6c… — the algorithm drifted from the fleet''s', left(d,16);
    END IF;
  ELSIF n = 30 THEN  -- v3.12 line — TWO roots now share this arithmetic (0.4.88)
    -- The shape COUNT stopped discriminating on 2026-08-28: wave-3.12-pass-1 added
    -- ckp:transportSegment as a PROPERTY shape on the existing ckp:KernelShape, so
    -- the NodeShape count stayed 30 while the structural digest moved. A single pin
    -- here would report a deliberate, declared content revision as ALGORITHM DRIFT —
    -- the exact misdiagnosis the comment above says this gate exists to prevent, one
    -- root later.
    --
    -- So the v3.12 line carries a KNOWN SET, each entry named. This is not a
    -- loosening: an unrecognised 30-shape digest still fails, which is what catches
    -- real drift. It is the same rule pgCK asked of CK.Lib.Js in A-8 — a digest is a
    -- per-deployment declaration, never one kit constant — applied to our own gate.
    -- The fleet legitimately runs both: dev benches boot the repo tree (pass-1) while
    -- the artifact bench boots the published FINAL, and that divergence is CORRECT.
    IF d NOT IN (
      -- v3.12 FINAL — the published root; what ckone and any baked bundle report
      '6e38f7bb631875b4fcacb086219d862bbe08cfc7209ee9c96967222e9c0225a7',
      -- v3.12 wave-3.12-pass-1 — FINAL + ckp:transportSegment on ckp:KernelShape
      -- (file 97f97cb2…); what a bench booting the repo /ontology tree reports
      '47d24485627e459f44aa5cb1fd414089cb63690b47ad1aabb610575acd096f4a'
    ) THEN
      RAISE EXCEPTION E's65 FAIL (1): v3.12 core (30 shapes) digest %… is not a KNOWN v3.12 pin.\n  known: 6e38f7bb… (FINAL, published) · 47d24485… (wave-3.12-pass-1, +transportSegment)\nEither the algorithm drifted, or the root''s bytes moved without adding its pin here. A new root revision adds its digest in the SAME commit as the bytes and the sidecar — never by widening this list to make a run pass.', left(d,16);
    END IF;
  ELSE
    RAISE EXCEPTION 's65 FAIL (1): loaded core carries % NodeShapes — neither founding arithmetic (27 v3.11 / 30 v3.12); the root is not one this gate knows', n;
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

-- (5) counts NAME their method and reproduce the founding arithmetic (F3),
--     PER ROOT (0.4.82, the v3.12-FINAL boot flip):
--       v3.11 core = 27 NodeShapes · 80 declared vocabulary properties
--       v3.12 core = 30 NodeShapes · 94 declared vocabulary properties
--     (94 = the same count the tests/v312-tdd audit instrument reports —
--      asserted owl/rdf declarations; predicted here, counted by the gate.)
DO $$
DECLARE res jsonb; g jsonb; ns int; dp int;
BEGIN
  res := ckp.dispatch('surface.grounding', jsonb_build_object('iri','urn:ckp:core'));
  g := res->'graphs'->0;
  ns := (g->>'nodeshapes')::int; dp := (g->>'declaredProperties')::int;
  -- Founding pairs, one per ROOT REVISION — not one per line (0.4.88). The v3.12 line
  -- carries two: FINAL, and wave-3.12-pass-1 which added ckp:transportSegment as a
  -- property declaration + a property shape on the existing ckp:KernelShape. NodeShapes
  -- stayed 30; declaredProperties moved 94 -> 95. A pair list that knows only one v3.12
  -- reports a declared, digest-pinned content revision as an instrument fault — the same
  -- misdiagnosis check (1) above was written to prevent.
  --
  -- This is NOT a loosening: an arithmetic outside the known set still fails, and a new
  -- revision adds its pair in the SAME commit as its bytes, its sidecar and its (1) pin.
  IF NOT ( (ns = 27 AND dp = 80)      -- v3.11
        OR (ns = 30 AND dp = 94)      -- v3.12 FINAL              (structural 6e38f7bb…)
        OR (ns = 30 AND dp = 95) )    -- v3.12 wave-3.12-pass-1   (structural 47d24485…)
  THEN
    RAISE EXCEPTION 's65 FAIL (5): core arithmetic %/% matches no known founding pair (27/80 v3.11 · 30/94 v3.12 FINAL · 30/95 v3.12 pass-1) — methods: asserted sh:NodeShape typing · asserted owl/rdf property declarations', ns, dp; END IF;
  IF NOT (g ? 'propertyShapes') THEN
    RAISE EXCEPTION 's65 FAIL (5): propertyShapes instrument missing — a count without its method is not a number'; END IF;
END $$;

\echo s65_structural_grounding: PASS
