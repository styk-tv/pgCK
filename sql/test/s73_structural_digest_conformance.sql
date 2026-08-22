-- s73_structural_digest_conformance.sql — THE CROSS-TOOL WITNESS MUST BE ONE NUMBER.
--
-- WHY THIS EXISTS. Two implementations of the same law now exist at two
-- boundaries, and that is correct rather than duplicated:
--
--   sporaxis   over a FILE, offline, in CI, BEFORE anything is loaded  → pre-flight
--   pgCK       over a LOADED GRAPH, at adoption/check                  → admission
--
-- A verifier that can only run after loading cannot refuse a bad module before
-- it reaches a store — which is exactly how an Adoption naming a sourceDigest of
-- sixty-four '1's sealed here on 2026-08-22, ok:true, four stamps, bytes that
-- exist nowhere. Pre-flight is the boundary that catches it.
--
-- BUT TWO WITNESSES ARE ONLY A WITNESS IF THEY AGREE. If an external verifier's
-- fingerprint diverges from ckp._structural_digest, it blesses modules this
-- substrate refuses — or, worse, blesses ones it should not — and the
-- cross-bench comparable collapses silently, in the confident direction. Until
-- (c) below passes on both sides, the two numbers are unrelated coincidences.
--
-- WHY A STRUCTURAL DIGEST AT ALL. Blank-node labels are per-parse. 51 of the 134
-- triples in sporaxis's compose.ttl touch a blank node, so an UNCHANGED law
-- reserialises to different bytes forever. A byte digest therefore cannot
-- witness identity across parses, stores or benches; only a structural one can.
-- The three planes are distinct and never interchange (R-14):
--
--   source     sha256 of the exact bytes the parser consumed
--   graph      the copy digest — bench-local
--   structural blank-node-immune — THE cross-bench witness
--
-- THE NORMATIVE LIMIT, stated because overclaiming it would be the defect this
-- file exists to prevent: DIFFERENT is CONCLUSIVE. Equality is
-- ISOMORPHIC_LIKELY — evidence, never proof — because first-degree hashing signs
-- only each node's immediate neighbourhood. Reporting equality as "identical" is
-- the same move as reading `verified: true` as JUDGED.
--
-- The claims:
--   (a) BLANK-NODE IMMUNITY. The same bytes parsed into a DIFFERENT graph —
--       every blank node relabelled — yield the SAME structural digest. Without
--       this the digest is a copy digest wearing another name.
--   (b) NEGATIVE CONTROL, and the half that matters: change ONE constraint and
--       the digest MUST move. A digest that cannot tell two different laws apart
--       cannot fail the thing it claims, and would report agreement forever.
--   (c) THE CONFORMANCE VECTOR. A fixed input and its expected digest, published
--       as the contract any external verifier must reproduce — the same form as
--       the FIPS vectors sporaxis already carries in-tree. If this value ever
--       changes, EVERY external claim of conformance is void until re-derived.
\set ON_ERROR_STOP 1

-- (a) + (b): immunity and sensitivity, measured against each other.
DO $$
DECLARE
  v_ttl   text;
  v_g1    int;
  v_g2    int;
  v_d_ref text;
  v_d_re  text;
  v_d_mod text;
BEGIN
  v_ttl := pg_read_file('/ontology/v3.12/modules/recon.ttl');

  -- reference parse
  SELECT pgrdf.add_graph('urn:ckp:s73:ref') INTO v_g1;
  PERFORM pgrdf.parse_turtle(v_ttl, v_g1, 'urn:ckp:module:recon#');
  SELECT ckp._structural_digest(v_g1) INTO v_d_ref;

  -- (a) SAME bytes, DIFFERENT graph: every blank node is relabelled by the parse
  SELECT pgrdf.add_graph('urn:ckp:s73:reparse') INTO v_g2;
  PERFORM pgrdf.parse_turtle(v_ttl, v_g2, 'urn:ckp:module:recon#');
  SELECT ckp._structural_digest(v_g2) INTO v_d_re;

  IF v_d_ref IS DISTINCT FROM v_d_re THEN
    PERFORM pgrdf.drop_graph('urn:ckp:s73:ref');
    PERFORM pgrdf.drop_graph('urn:ckp:s73:reparse');
    RAISE EXCEPTION 's73 FAIL (a): the digest MOVED across a reparse of identical bytes (% vs %). It is a copy digest, not a structural one, and cannot witness a module across parses, stores or benches.',
      left(v_d_ref,16), left(v_d_re,16);
  END IF;
  RAISE NOTICE 's73 (a) PASS — blank-node immune: identical bytes, different graph, digest %', left(v_d_ref,16);

  -- (b) NEGATIVE CONTROL: one constraint changed. maxCount 1 -> 2 on recon:text
  -- is a REAL change of law (a chunk could carry two texts), so the digest must
  -- move. Reuse the reparse graph, mutated.
  PERFORM pgrdf.drop_graph('urn:ckp:s73:reparse');
  SELECT pgrdf.add_graph('urn:ckp:s73:mutated') INTO v_g2;
  PERFORM pgrdf.parse_turtle(
    replace(v_ttl,
      'sh:path recon:text    ; sh:minCount 1 ; sh:maxCount 1',
      'sh:path recon:text    ; sh:minCount 1 ; sh:maxCount 2'),
    v_g2, 'urn:ckp:module:recon#');
  SELECT ckp._structural_digest(v_g2) INTO v_d_mod;

  PERFORM pgrdf.drop_graph('urn:ckp:s73:ref');
  PERFORM pgrdf.drop_graph('urn:ckp:s73:mutated');

  IF v_d_mod IS NOT DISTINCT FROM v_d_ref THEN
    RAISE EXCEPTION 's73 FAIL (b): maxCount 1 -> 2 on recon:text did NOT move the digest. The fingerprint cannot distinguish two different laws, so it would report agreement between any two modules forever — a witness that can never refuse.';
  END IF;
  RAISE NOTICE 's73 (b) PASS — sensitive: one changed constraint moves the digest (% -> %)',
    left(v_d_ref,16), left(v_d_mod,16);
END $$;

-- (c) THE PUBLISHED CONFORMANCE VECTOR.
-- recon.ttl (v3.12 spore) MUST fingerprint to this value. External verifiers
-- claiming conformance with ckp._structural_digest reproduce it or they are not
-- conformant — there is no third outcome, and "close enough" is not one either.
--
-- IF THIS CONSTANT EVER CHANGES, every external conformance claim is VOID until
-- re-derived on both sides. Do not update it to make the test pass; find out
-- which side moved and why.
-- TWO vectors during the recon namespace transition, and both are load-bearing.
-- recon was authored at v3.12/recon# in error: wave and lexicon set the
-- convention that a module namespace tracks the ONTOLOGY LINE, not the release,
-- and RC2 itself still binds ckp: -> v3.11/core#. It is re-issued at
-- v3.11/recon#.
--
-- The old module STAYS IN THE TREE AND IN THE STORE until every adopter has
-- superseded — R-10 (beside, never over) applied to modules. Four kernels
-- currently compose against v3.12/recon#, and ckp._composed_shapes FAILS CLOSED
-- on an adopted graph that is absent, so deleting it would take four surfaces
-- down at once to fix a namespace.
--
-- Both are 33 quads and structurally identical in topology; the pins differ
-- because the type IRIs differ. That is correct — a renamed type IS a different
-- law — and it is a third sensitivity check for free.
DO $$
DECLARE
  v_g int; v_d text; v_path text; v_exp text; r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    -- old: live, adopted by four kernels, retire only when all have superseded
    ('/ontology/v3.12/modules/recon.ttl',
     'ec769d2c527631c6335bb19c77dbc87b6b6459f6674547e331fdfe8831b3c97f'),
    -- new: the forward vector external verifiers must reproduce
    ('/ontology/v3.11/modules/recon.ttl',
     'c13ea7ee6768961d1c9d2fe99bb98887d4ba862bba95e7e29c1ba511ec576ec5')
  ) AS t(path, expected)
  LOOP
    SELECT pgrdf.add_graph('urn:ckp:s73:vector') INTO v_g;
    PERFORM pgrdf.parse_turtle(pg_read_file(r.path), v_g, 'urn:ckp:module:recon#');
    SELECT ckp._structural_digest(v_g) INTO v_d;
    PERFORM pgrdf.drop_graph('urn:ckp:s73:vector');

    IF v_d IS DISTINCT FROM r.expected THEN
      RAISE EXCEPTION E's73 FAIL (c): CONFORMANCE VECTOR MOVED for %.\n  expected %\n  actual   %\nEither the module changed (then this constant AND every external verifier re-derive TOGETHER, in one cut) or ckp._structural_digest changed (then every previously published pin is void). Establish WHICH before touching either. Do NOT edit the constant to make this pass.',
        r.path, r.expected, v_d;
    END IF;
    RAISE NOTICE 's73 (c) PASS — % -> %', r.path, left(v_d,16);
  END LOOP;

  RAISE NOTICE 's73 LIMIT — equality here is ISOMORPHIC_LIKELY, not proof. DIFFERENT is conclusive; do not report a match as "identical".';
END $$;

SELECT 's73_structural_digest_conformance: PASS';
