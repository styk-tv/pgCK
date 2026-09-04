-- s91 — KNOW BEFORE YOU ACT, AND AT THE ACT: the adoption reference checks
-- ride the dry-run (PRE) and the seal reply (AT), and the projector refusal
-- routes the adopter's intent (D-2).
--
-- 0.4.112. Operator ruling 2026-09-04: "this entire system is based on the
-- fact that validation is cheap — run it and know before you act." The census
-- (fleet.adoptions, s90) and the audit (adoption.check) answered these
-- questions DOWNSTREAM only; a stranger seat (ck-dev) walked into every one of
-- them blind. This gate proves the same three checks now answer at the two
-- earlier moments — and that the refusal that used to strand the stranger now
-- names the correct route.
--
-- B4 holds throughout: reference failures WARN, they never gate. Case (e)
-- asserts the seal STANDS with the warning beside it — a refusal here would be
-- the outage class the census was built to avoid. Negative controls: (a) and
-- (f) prove the warnings are absent when the references are sound — a flag
-- that fires on everything reports nothing.
\set ON_ERROR_STOP on

-- setup: a module THIS test loads, so the loader's record is known and ours.
DO $$
DECLARE v_g bigint;
BEGIN
  PERFORM set_config('ckp.project', 'demo', false);
  PERFORM set_config('ckp.requester', 'svc:s91-smoke', true);
  v_g := pgrdf.add_graph('urn:ckp:module:s91mod');
  PERFORM pgrdf.clear_graph(v_g);
  PERFORM pgrdf.parse_turtle(
    '@prefix s91: <urn:ckp:domain:s91#> . @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> . s91:Thing a rdfs:Class ; rdfs:label "s91 probe type" .',
    v_g, 'urn:ckp:module:s91mod#');
END $$;

DO $$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_rec text; res jsonb; v_ref jsonb; v_nwarn int;
BEGIN
  PERFORM set_config('ckp.project', 'demo', false);
  PERFORM set_config('ckp.requester', 'svc:s91-smoke', true);
  SELECT source_sha256 INTO v_rec FROM pgrdf._pgrdf_graphs WHERE iri = 'urn:ckp:module:s91mod';
  IF v_rec IS NULL THEN
    RAISE EXCEPTION 's91 SETUP FAIL: parse_turtle recorded no source_sha256 — the premise (turtle funnel records) does not hold on this engine'; END IF;

  -- (a) PRE, clean — THE NEGATIVE CONTROL FIRST. Correct digest, real module,
  --     real target: reference present, all three sound, ZERO reference warnings.
  res := ckp.dispatch('instance.validate', jsonb_build_object(
    'type', N||'Adoption',
    N||'adopts', 'urn:ckp:module:s91mod', N||'intoProject', 'urn:ckp:project:demo',
    N||'sourceDigest', v_rec, N||'intoEpoch', 0));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's91 FAIL (a): validate: %', res; END IF;
  v_ref := res->'reference';
  IF v_ref IS NULL THEN RAISE EXCEPTION 's91 FAIL (a): dry-run carries no `reference` — PRE does not exist'; END IF;
  IF (v_ref->>'sourceDigestMatch')::boolean IS DISTINCT FROM true
     OR (v_ref->>'moduleResolves')::boolean IS DISTINCT FROM true
     OR (v_ref->>'targetHasGraphs')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 's91 FAIL (a): sound references read unsound: %', v_ref; END IF;
  SELECT count(*) INTO v_nwarn FROM jsonb_array_elements(COALESCE(res->'warnings','[]'::jsonb)) w WHERE w ? 'check';
  IF v_nwarn <> 0 THEN
    RAISE EXCEPTION 's91 FAIL (a): % reference warning(s) on a SOUND candidate — a flag that fires on everything reports nothing: %', v_nwarn, res->'warnings'; END IF;

  -- (b) PRE, wrong digest — doctrine wearing a digest is named BEFORE the act.
  res := ckp.dispatch('instance.validate', jsonb_build_object(
    'type', N||'Adoption',
    N||'adopts', 'urn:ckp:module:s91mod', N||'intoProject', 'urn:ckp:project:demo',
    N||'sourceDigest', repeat('9',64), N||'intoEpoch', 0));
  IF (res->'reference'->>'sourceDigestMatch')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 's91 FAIL (b): a wrong digest read sourceDigestMatch=% — the mis-citation class survives the dry-run: %', res->'reference'->>'sourceDigestMatch', res->'reference'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'warnings') w WHERE w->>'check' = 'sourceDigestMatch') THEN
    RAISE EXCEPTION 's91 FAIL (b): no sourceDigestMatch warning — the caller is not told: %', res->'warnings'; END IF;

  -- (c) PRE, dangling module — the census''s malformed class, at the dry-run.
  res := ckp.dispatch('instance.validate', jsonb_build_object(
    'type', N||'Adoption',
    N||'adopts', 'urn:ckp:module:s91-absent', N||'intoProject', 'urn:ckp:project:demo',
    N||'sourceDigest', repeat('a',64), N||'intoEpoch', 0));
  IF (res->'reference'->>'moduleResolves')::boolean IS DISTINCT FROM false
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'warnings') w WHERE w->>'check' = 'moduleResolves') THEN
    RAISE EXCEPTION 's91 FAIL (c): a module that resolves to NOTHING was not flagged at PRE: %', res->'reference'; END IF;

  -- (d) PRE, dangling target — s90''s orphaned class, at the dry-run.
  res := ckp.dispatch('instance.validate', jsonb_build_object(
    'type', N||'Adoption',
    N||'adopts', 'urn:ckp:module:s91mod', N||'intoProject', 'urn:ckp:project:s91-nowhere',
    N||'sourceDigest', v_rec, N||'intoEpoch', 0));
  IF (res->'reference'->>'targetHasGraphs')::boolean IS DISTINCT FROM false
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'warnings') w WHERE w->>'check' = 'targetHasGraphs') THEN
    RAISE EXCEPTION 's91 FAIL (d): a target project with NO graphs was not flagged at PRE: %', res->'reference'; END IF;

  -- (e) AT, wrong digest — the seal STANDS (B4) and the reply says so AT THE ACT.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type', N||'Adoption', '@id', 'urn:s91:at-wrong',
    N||'adopts', 'urn:ckp:module:s91mod', N||'intoProject', 'urn:ckp:project:demo',
    N||'sourceDigest', repeat('9',64), N||'intoEpoch', 0));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's91 FAIL (e): the seal was REFUSED — reference checks must WARN, never gate (B4): %', res; END IF;
  IF (res->'reference'->>'sourceDigestMatch')::boolean IS DISTINCT FROM false
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'warnings') w WHERE w->>'check' = 'sourceDigestMatch') THEN
    RAISE EXCEPTION 's91 FAIL (e): sealed ok but the reply does not say the digest is wrong — the caller learns downstream or never: %', res; END IF;

  -- (f) AT, clean — NEGATIVE CONTROL: sound seal carries no reference warnings.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type', N||'Adoption', '@id', 'urn:s91:at-clean',
    N||'adopts', 'urn:ckp:module:s91mod', N||'intoProject', 'urn:ckp:project:demo',
    N||'sourceDigest', v_rec, N||'intoEpoch', 0));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's91 FAIL (f): clean seal refused: %', res; END IF;
  IF (res->'reference'->>'sourceDigestMatch')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 's91 FAIL (f): a correct digest read match=% at the act: %', res->'reference'->>'sourceDigestMatch', res->'reference'; END IF;
  SELECT count(*) INTO v_nwarn FROM jsonb_array_elements(COALESCE(res->'warnings','[]'::jsonb)) w WHERE w ? 'check';
  IF v_nwarn <> 0 THEN
    RAISE EXCEPTION 's91 FAIL (f): reference warning(s) on a SOUND seal: %', res->'warnings'; END IF;

  RAISE NOTICE 's91 (a-f) PASS — the three reference checks answer at PRE and AT, warn on the broken, stay silent on the sound, and never gate';
END $$;

-- (g,h) D-2 — the refusal that stranded the stranger now routes the intent.
DO $$
DECLARE res jsonb; v_teach text;
BEGIN
  PERFORM set_config('ckp.project', 'demo', false);
  PERFORM set_config('ckp.requester', 'svc:s91-smoke', true);
  res := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op', 'adopt_module', 'about', 'urn:ckp:module:s91mod'));
  IF (res->>'ok') IS DISTINCT FROM 'false' OR res->>'error' IS DISTINCT FROM 'op_has_no_projector' THEN
    RAISE EXCEPTION 's91 FAIL (g): adopt_module as a governed op must still refuse op_has_no_projector: %', res; END IF;
  IF res->>'hint' NOT ILIKE '%core#Adoption%' OR res->>'hint' NOT ILIKE '%instance.validate%' THEN
    RAISE EXCEPTION 's91 FAIL (g): the refusal names what is invalid but not the route the intent needs (rule 19): %', res->>'hint'; END IF;
  SELECT teaches INTO v_teach FROM ckp.refusal_registry WHERE code = 'op_has_no_projector';
  IF v_teach IS NULL OR v_teach NOT ILIKE '%instance.create%' OR v_teach NOT ILIKE '%surface.declared%' THEN
    RAISE EXCEPTION 's91 FAIL (h): the registry teach does not route adoption (got: %)', v_teach; END IF;
  RAISE NOTICE 's91 (g-h) PASS — op_has_no_projector routes the adopter to instance.create, in the hint and in the registry';
END $$;

SELECT 's91 PASS — know before you act (PRE), know at the act (AT), and the wrong door points at the right one (D-2)' AS result;
