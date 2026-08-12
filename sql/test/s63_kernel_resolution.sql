-- s63 — KERNEL RESOLUTION: the caller's own surface first, the seeded floor second.
--
-- WHY THIS EXISTS. Nothing in the suite dispatched as more than one kernel, so
-- ckp.dispatch could resolve EVERY caller's affordances under one fixed name and
-- stay green:
--     v_aff := ckp.registry_lookup('pgck', v_canon);      -- until 0.4.46
-- A verb registered, voted through and applied by any other kernel was invisible
-- to its own owner. It looked correct only because the seed and the registrars
-- were hard-coded to the SAME literal -- writer and reader wrong in the same
-- direction, which is symmetry, not agreement. Correcting one side is what made
-- it visible, and 0.4.47 then shipped the wrong dispatch OVERLOAD with both
-- gates still green, because both install from the baseline.
--
-- The four claims below are the ones that were untested:
--   (a) a kernel resolves the verb IT registered
--   (b) a kernel does NOT resolve another kernel's verb   <- fail-closed
--   (c) a kernel owning nothing still reaches the SEEDED floor
--   (d) the shipped seed names the canonical kernel form only
--
-- Canonical form: a project name is one transport segment, lowercase, dashes
-- optional. NATS subjects are case-sensitive, so an uppercase segment in the
-- seed is a surface no conforming client can address.
\set ON_ERROR_STOP 1

-- (a) alpha registers a query affordance through the governance plane and calls it.
SET ckp.project = 's63-alpha';
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; res jsonb;
  Q text := 'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> '
         || 'SELECT ?s WHERE { GRAPH ?g { ?s rdfs:label ?l } } LIMIT 1';
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_affordance', 'about','urn:ckp:s63-alpha/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('verb','s63.alpha.probe', 'query',Q, 'params','[]'::jsonb)));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's63 FAIL (a): propose: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's63 FAIL (a): vote: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap#>>'{applied,query_affordance}') <> 's63.alpha.probe' THEN
    RAISE EXCEPTION 's63 FAIL (a): not registered at apply: %', ap; END IF;

  res := ckp.dispatch('s63.alpha.probe', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's63 FAIL (a): alpha cannot call the verb it registered: %', res; END IF;
END $$;

-- (b) beta must NOT reach alpha's verb. Cross-kernel leakage is fail-OPEN
--     authorization: the row exists, but it is not beta's to call.
SET ckp.project = 's63-beta';
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('s63.alpha.probe', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'false' OR (res->>'error') <> 'unknown_affordance' THEN
    RAISE EXCEPTION 's63 FAIL (b): beta reached alpha''s verb — cross-kernel leakage: %', res;
  END IF;
END $$;

-- (c) beta owns no affordance of its own, and must still reach the SEEDED floor.
--     Resolving ONLY the caller made the seeded substrate verbs unreachable for
--     every project (the s32 failure); resolving ONLY the floor made every kernel
--     share one name's surface. Both halves are load-bearing.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('instance.query',
           jsonb_build_object('type','https://conceptkernel.org/ontology/v3.11/core#Kernel'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's63 FAIL (c): a kernel owning nothing cannot reach the seeded floor: %', res;
  END IF;
END $$;

-- (d) the shipped seed names the canonical form only. An uppercase segment here
--     is a surface no conforming client can address, because NATS subjects are
--     case-sensitive and a correct client slugs its workspace.
--     Scoped to the SEEDED verbs, not every row: s17/s18 register a synthetic
--     'TestK' to unit-test registry_lookup, and a lookup legitimately does not
--     care about case. The claim here is narrower and is the one that broke --
--     the substrate publishing ITS OWN surface under a name no conforming
--     client can address.
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(DISTINCT kernel||' ('||verb||')', ', ') INTO bad
    FROM ckp.affordance_registry
   WHERE verb IN ('instance.query','affordances','kernel.germinate',
                  'kernel.propose_change','kernel.vote','kernel.apply')
     AND kernel !~ '^[a-z0-9]+(-[a-z0-9]+)*$';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 's63 FAIL (d): the substrate seeds its own surface under a non-canonical, unaddressable kernel name: %', bad;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ckp.affordance_registry WHERE verb='instance.query') THEN
    RAISE EXCEPTION 's63 FAIL (d): no seeded instance.query row — the assertion would pass vacuously';
  END IF;
END $$;

RESET ckp.project;
SELECT 's63_kernel_resolution: PASS';
