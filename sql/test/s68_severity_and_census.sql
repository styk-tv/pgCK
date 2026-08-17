-- s68_severity_and_census.sql — GUIDANCE AS VALIDATION (0.4.72, vision §2).
--
--   (1) SEVERITY GATE: a warning-severity shape lets a body SEAL and surfaces
--       the warning in the reply; a violation-severity (and default-severity)
--       shape still REFUSES — nothing weakens (the negative control).
--   (2) VALIDATE ⟺ SEAL, fourth axis: the dry-run reports conforms=true with
--       the same warnings the seal surfaces — no split.
--   (3) THE RATCHET: adopt the no-warnings obligation and the SAME warning
--       becomes a refusal naming the regime; deactivate and it seals again.
--   (4) adopts-resolves: an Adoption naming a graph-less IRI (the ontosys
--       class) REFUSES under the obligation; adopting a real graph seals.
--   (5) fleet.adoptions flags a malformed adoption sealed WITHOUT the
--       obligation, so the census catches what no gate was asked to.
--   (6) surface.explain returns the class comment and per-property prose for
--       a core type — the shape teaches its prose through the door.
--
-- Run (booted by the smoke): psql … < s68_severity_and_census.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's68-test';

-- (0) fixture: a governed type whose shape carries BOTH severities — name
-- required (default = Violation), note recommended (explicit sh:Warning).
-- add_class's projector has no severity knob (deliberate scope), so the
-- warning property-shape is declared via governed raw shape application on
-- this kernel's own graph: add_class first, then the warning shape joins the
-- kernel graph through apply_shape_ttl's governed path (add_property emits
-- default severity; the warning band is authored where module authors author).
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; ga jsonb;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_class', 'about','urn:ckp:s68-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('class','urn:ckp:s68-test/type/Card',
      'properties', jsonb_build_array(jsonb_build_object('path','urn:ckp:s68-test/prop/name','minCount',1)))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (0): propose: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (0): apply: %', ap; END IF;
  -- the warning-severity shape, named per R-9, into the kernel graph.
  ga := ckp.apply_shape_ttl('@prefix sh: <http://www.w3.org/ns/shacl#> .
    <urn:ckp:s68-test/shape/card-guidance> a sh:NodeShape ;
      sh:targetClass <urn:ckp:s68-test/type/Card> ;
      sh:property <urn:ckp:s68-test/shape/card-guidance/p> .
    <urn:ckp:s68-test/shape/card-guidance/p> sh:path <urn:ckp:s68-test/prop/note> ;
      sh:minCount 1 ; sh:severity sh:Warning .', 's68-test');
  IF (ga->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (0): guidance shape: %', ga; END IF;
END $$;

-- (1) warning surfaces, seal succeeds; violation still refuses.
DO $$
DECLARE res jsonb;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s68-suite', true);
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card', '@id','urn:s68:card-warned',
    'urn:ckp:s68-test/prop/name','has a name, lacks the recommended note'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (1): a warnings-only body REFUSED — the gate did not learn severity: %', res; END IF;
  IF NOT (res ? 'warnings') OR jsonb_array_length(res->'warnings') < 1 THEN
    RAISE EXCEPTION 's68 FAIL (1): sealed but the warning did not surface in the reply: %', res; END IF;
  IF (res->'warnings'->0->>'resultSeverity') <> 'sh:Warning' THEN
    RAISE EXCEPTION 's68 FAIL (1): surfaced result is not the warning: %', res->'warnings'; END IF;
  -- negative control: the default-severity requirement still refuses.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card', '@id','urn:s68:card-nameless',
    'urn:ckp:s68-test/prop/note','note without the required name'));
  IF (res->>'ok') IS NOT DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (1): a VIOLATION sealed — severity handling weakened the gate'; END IF;
END $$;

-- engine hygiene after the deliberate abort.
DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (2) validate ⟺ seal on the severity axis.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('instance.validate', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card',
    'urn:ckp:s68-test/prop/name','dry run, no note'));
  IF (res->>'conforms') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (2): dry-run says conforms=false for a warnings-only body the seal accepts — the split is back: %', res; END IF;
  IF jsonb_array_length(COALESCE(res->'warnings','[]'::jsonb)) < 1 THEN
    RAISE EXCEPTION 's68 FAIL (2): dry-run hides the warning the seal would surface: %', res; END IF;
END $$;

-- (3) the ratchet: no-warnings adopted → the same body refuses; removed → seals.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; res jsonb;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_proof_obligation', 'about','urn:ckp:s68-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('obligation','strict-output','targetType','urn:ckp:s68-test/type/Card','check','no-warnings')));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (3): propose: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (3): apply: %', ap; END IF;
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card', '@id','urn:s68:card-strict',
    'urn:ckp:s68-test/prop/name','same warning body under the strict regime'));
  IF (res->>'ok') IS NOT DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (3): the strict regime sealed a warning-bearing body — the ratchet does not bite'; END IF;
  IF res->>'error' !~ 'no-warnings' THEN
    RAISE EXCEPTION 's68 FAIL (3): refused for the wrong reason: %', res->>'error'; END IF;
  -- conforming body under strict regime seals WITH the warranty row.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card', '@id','urn:s68:card-clean',
    'urn:ckp:s68-test/prop/name','named', 'urn:ckp:s68-test/prop/note','and noted'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (3): clean body refused under strict: %', res; END IF;
  PERFORM 1 FROM ckp.proof WHERE about = (res->>'id') AND method = 'obligation:strict-output';
  IF NOT FOUND THEN RAISE EXCEPTION 's68 FAIL (3): the warranty row is missing — reliance is a vibe again'; END IF;
  -- the road out.
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_proof_obligation', 'about','urn:ckp:s68-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('obligation','strict-output','active','false')));
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s68-test/type/Card', '@id','urn:s68:card-relaxed',
    'urn:ckp:s68-test/prop/name','warning body after deactivation'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (3): post-deactivation warning body refused: %', res; END IF;
END $$;

DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (4) adopts-resolves: the ontosys class refused under the obligation; a real
--     graph adopts. (5) the census flags a malformed adoption — sealed under a
--     SACRIFICIAL project, because 0.4.61's fail-closed composer takes a
--     project DOWN at its next seal once a dangling adoption is in (measured
--     right here on the first cut of this test: the guard must come first at
--     home, and the census's quarry must be someone we never seal as again).
--     That is also the live ontosys condition this release exists to prevent.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; res jsonb; v_flags int;
BEGIN
  -- the census's quarry, under the victim project (its poison harms nobody:
  -- no further seals ever happen as s68-victim).
  PERFORM set_config('ckp.project', 's68-victim', false);
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','https://conceptkernel.org/ontology/v3.11/core#Adoption', '@id','urn:s68:adoption-bad',
    'https://conceptkernel.org/ontology/v3.11/core#adopts','urn:ckp:s68-test/no-such-graph',
    'https://conceptkernel.org/ontology/v3.11/core#intoProject','urn:ckp:project:s68-victim',
    'https://conceptkernel.org/ontology/v3.11/core#sourceDigest', repeat('a',64),
    'https://conceptkernel.org/ontology/v3.11/core#intoEpoch', 1));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (5): unguarded malformed adoption should seal (that is the defect class): %', res; END IF;
  PERFORM set_config('ckp.project', 's68-test', false);
  -- now the guard AT HOME, by governance, before anything dangling can land here.
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_proof_obligation', 'about','urn:ckp:s68-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('obligation','adoptions-resolve','targetType','https://conceptkernel.org/ontology/v3.11/core#Adoption','check','adopts-resolves')));
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (4): apply: %', ap; END IF;
  -- ontosys class now refuses…
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','https://conceptkernel.org/ontology/v3.11/core#Adoption', '@id','urn:s68:adoption-bad2',
    'https://conceptkernel.org/ontology/v3.11/core#adopts','https://conceptkernel.org/ontology/v3.11/wave',
    'https://conceptkernel.org/ontology/v3.11/core#intoProject','urn:ckp:project:s68-test',
    'https://conceptkernel.org/ontology/v3.11/core#sourceDigest', repeat('b',64),
    'https://conceptkernel.org/ontology/v3.11/core#intoEpoch', 1));
  IF (res->>'ok') IS NOT DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's68 FAIL (4): a graph-less adopts SEALED under adopts-resolves'; END IF;
  IF res->>'error' !~ 'adopts-resolves' THEN
    RAISE EXCEPTION 's68 FAIL (4): refused for the wrong reason: %', res->>'error'; END IF;
  -- …and a real graph adopts.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','https://conceptkernel.org/ontology/v3.11/core#Adoption', '@id','urn:s68:adoption-good',
    'https://conceptkernel.org/ontology/v3.11/core#adopts','urn:ckp:core',
    'https://conceptkernel.org/ontology/v3.11/core#intoProject','urn:ckp:project:s68-test',
    'https://conceptkernel.org/ontology/v3.11/core#sourceDigest','e5f7d1e54b32fa0ba2d41ba248e0909b96ee1ebb4344e2d9e9ccdf4e0b25348d',
    'https://conceptkernel.org/ontology/v3.11/core#intoEpoch', 1));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (4): adopting a real graph refused: %', res; END IF;
  -- the census sees the unguarded malformed row.
  res := ckp.dispatch('fleet.adoptions', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (5): fleet.adoptions: %', res; END IF;
  SELECT count(*) INTO v_flags FROM jsonb_array_elements(res->'adoptions') r
   WHERE r->>'adopts' = 'urn:ckp:s68-test/no-such-graph' AND (r->>'malformed')::boolean;
  IF v_flags <> 1 THEN
    RAISE EXCEPTION 's68 FAIL (5): the census did not flag the malformed adoption (found % flags)', v_flags; END IF;
END $$;

DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (6) the shape teaches its prose.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('surface.explain', jsonb_build_object('type','https://conceptkernel.org/ontology/v3.11/core#Adoption'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's68 FAIL (6): surface.explain: %', res; END IF;
  IF COALESCE(res->>'comment','') = '' THEN
    RAISE EXCEPTION 's68 FAIL (6): core#Adoption has a class comment in the root and the verb returned none'; END IF;
  IF jsonb_array_length(res->'properties') < 3 THEN
    RAISE EXCEPTION 's68 FAIL (6): expected the declared property contract with prose, got %', res->'properties'; END IF;
END $$;

\echo s68_severity_and_census: PASS
