-- s41_governed_query_affordance.sql — Tier 2 (3/3b): the §6.3 governed query form.
--
-- A kernel declares a parameterized query affordance through the GOVERNANCE plane (the SPARQL
-- text is authored once, sealed via propose -> vote -> apply, compiled into ckp.plans), then
-- exposes it under a verb. Callers bind typed param VALUES only; they never see or alter the
-- query text. This is the only sanctioned "SPARQL affordance for clients".
--   (1) govern-add a `demo.search` label query (apply reports query_affordance registered);
--   (2) a ck_participant dispatches it with a bound term and gets the matching row;
--   (2b) different terms bind differently (one match / none) — the param really binds;
--   (3) an injection-shaped param VALUE is rejected by the value gate, never reaching the query;
--   (4) a caller cannot supply raw query text — only declared params bind; a stray `query` key
--       is ignored and the sealed query still runs.
--
-- Run (booted by the smoke): psql … < s41_governed_query_affordance.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's41-test';

-- seed labeled RDF data the governed query will search.
DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s41-test/data');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle(
    '<urn:s41:ship-a> <http://www.w3.org/2000/01/rdf-schema#label> "USS Defiant Ship" .
     <urn:s41:ship-b> <http://www.w3.org/2000/01/rdf-schema#label> "Voyager Vessel" .',
    g, 'urn:ckp:s41-test/data#');
END $setup$;

-- (1) govern-add a label-search query affordance through the governance plane.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text;
  Q text := 'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> '
          || 'SELECT ?s ?l WHERE { GRAPH ?g { ?s rdfs:label ?l . FILTER(CONTAINS(STR(?l), "$term$")) } }';
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_affordance', 'about','urn:ckp:s41-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('verb','demo.search', 'query',Q, 'params', jsonb_build_array('term'))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's41 FAIL (1): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's41 FAIL (1): vote rejected: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's41 FAIL (1): apply rejected: %', ap; END IF;
  IF (ap#>>'{applied,query_affordance}') <> 'demo.search' THEN
    RAISE EXCEPTION 's41 FAIL (1): query affordance not registered at apply: %', ap; END IF;
END $$;

-- (2) a participant dispatches the governed verb with a bound term — matching rows, no query text.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('demo.search', '{"term":"Defiant"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's41 FAIL (2): governed query not ok: %', res; END IF;
  IF (res->>'count')::int < 1 THEN RAISE EXCEPTION 's41 FAIL (2): expected a match for "Defiant": %', res; END IF;
END $$;

-- (2b) different bound terms bind differently — the param actually drives the query.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('demo.search', '{"term":"Voyager"}'::jsonb);
  IF (res->>'count')::int < 1 THEN RAISE EXCEPTION 's41 FAIL (2b): "Voyager" should match ship-b: %', res; END IF;
  res := ckp.dispatch('demo.search', '{"term":"zzznotthere"}'::jsonb);
  RESET ROLE;
  IF (res->>'count')::int <> 0 THEN RAISE EXCEPTION 's41 FAIL (2b): a nonexistent term must match nothing: %', res; END IF;
END $$;

-- (3) an injection-shaped param VALUE is rejected by the value gate (never reaches the query).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('demo.search', jsonb_build_object('term','x") } UNION { ?a ?b ?c FILTER("'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_param' THEN RAISE EXCEPTION 's41 FAIL (3): injection param not rejected: %', res; END IF;
END $$;

-- (4) the caller cannot supply raw query text — only declared params bind; a stray `query` key is
--     ignored and the SEALED query still runs (here matching "Ship").
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('demo.search',
    jsonb_build_object('term','Ship', 'query','SELECT ?evil WHERE { ?evil ?p ?o }'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's41 FAIL (4): %', res; END IF;
  IF (res->>'count')::int < 1 THEN
    RAISE EXCEPTION 's41 FAIL (4): the sealed governed query (not the caller query) should run for term=Ship: %', res; END IF;
END $$;

\echo s41_governed_query_affordance: PASS
