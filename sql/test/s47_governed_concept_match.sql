-- s47_governed_concept_match.sql — v0.5 roadmap T6: the governed concept.match.
--
-- concept.match is now served by a SEALED query in ckp.plans (the §6.3 governed form), running a
-- SPARQL label search over the per-project instance graph (projected by the label trigger):
--   (1) the concept.match query is a GOVERNED plan in ckp.plans (not a hardcoded function);
--   (2) concept.match{term} runs that governed query (governed:true) and returns the matching tasks;
--   (2b) a different term binds differently (the param drives the search);
--   (3) a caller cannot pass raw query text — only the term binds; an injection-shaped term is BOUND
--       into the literal (matches nothing), never injects.
--
-- Run (booted by the smoke): psql … < s47_governed_concept_match.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's47-test';

-- create tasks with distinctive titles (the trigger projects each title as rdfs:label).
DO $$
BEGIN
  SET LOCAL ROLE ck_participant;
  PERFORM ckp.dispatch('instance.create','{"task":{"target_kernel":"s47","title":"Rotate SPIFFE certificates"}}'::jsonb);
  PERFORM ckp.dispatch('instance.create','{"task":{"target_kernel":"s47","title":"Audit firewall rules"}}'::jsonb);
  PERFORM ckp.dispatch('instance.create','{"task":{"target_kernel":"s47","title":"Rotate database passwords"}}'::jsonb);
  RESET ROLE;
END $$;

-- (1) concept.match is a GOVERNED plan in ckp.plans (not the hardcoded function).
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ckp.plans WHERE kernel='pgCK' AND verb='concept.match' AND plan->>'kind'='sparql';
  IF n < 1 THEN RAISE EXCEPTION 's47 FAIL (1): concept.match is not a governed plan in ckp.plans'; END IF;
END $$;

-- (2) concept.match{term} runs the governed query and returns the matching tasks.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', '{"term":"rotate"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's47 FAIL (2): concept.match not ok: %', res; END IF;
  IF (res->>'governed') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's47 FAIL (2): concept.match should run the GOVERNED query: %', res; END IF;
  IF (res->>'count')::int <> 2 THEN
    RAISE EXCEPTION 's47 FAIL (2): "rotate" should match 2 tasks (SPIFFE, passwords), got %: %', res->>'count', res; END IF;
END $$;

-- (2b) a different term binds differently.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', '{"term":"firewall"}'::jsonb);
  IF (res->>'count')::int <> 1 THEN RAISE EXCEPTION 's47 FAIL (2b): "firewall" should match 1: %', res; END IF;
  res := ckp.dispatch('concept.match', '{"term":"zzznotthere"}'::jsonb);
  RESET ROLE;
  IF (res->>'count')::int <> 0 THEN RAISE EXCEPTION 's47 FAIL (2b): a nonexistent term must match nothing: %', res; END IF;
END $$;

-- (3) a caller cannot pass raw query text — an injection-shaped term is BOUND (matches nothing), never injects.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', jsonb_build_object('term','x") } UNION { ?a ?b ?c FILTER("'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's47 FAIL (3): injection term should be bound, not error: %', res; END IF;
  IF (res->>'count')::int <> 0 THEN RAISE EXCEPTION 's47 FAIL (3): injection term matched % (NOT bound into the literal)', res->>'count'; END IF;
END $$;

\echo s47_governed_concept_match: PASS
