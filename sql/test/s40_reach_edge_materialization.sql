-- s40_reach_edge_materialization.sql — Tier 2 (3/3a): reach traverses real edges.
--
-- Before this, edge.create sealed an Edge instance but wrote no quad, so a participant
-- who linked instances then called reach got [] (s30 only passed by pre-seeding quads).
-- Now edge.create materializes a traversable quad. This test goes entirely through the
-- dispatch door as a real ck_participant:
--   (1) edge.create A->B and B->C — both report reachable:true (quad materialized);
--   (2) reach(from=A, via=pred) returns {B, C} transitively — participant edges traverse;
--   (3) a bare (non-IRI) endpoint seals the Edge instance but is honestly reachable:false.
--
-- Run (booted by the smoke): psql … < s40_reach_edge_materialization.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's40-test';

-- (1) two participant-created edges A->B->C through the door — materialized as quads.
DO $$
DECLARE r1 jsonb; r2 jsonb; P text := 'https://conceptkernel.org/ontology/v3.8/core#link';
BEGIN
  SET LOCAL ROLE ck_participant;
  r1 := ckp.dispatch('edge.create', jsonb_build_object('source','urn:ckp:s40/a','predicate',P,'target','urn:ckp:s40/b'));
  r2 := ckp.dispatch('edge.create', jsonb_build_object('source','urn:ckp:s40/b','predicate',P,'target','urn:ckp:s40/c'));
  RESET ROLE;
  IF (r1->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's40 FAIL (1): edge A->B not sealed: %', r1; END IF;
  IF (r1->>'reachable') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's40 FAIL (1): edge A->B not materialized as a quad: %', r1; END IF;
  IF (r2->>'reachable') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's40 FAIL (1): edge B->C not materialized: %', r2; END IF;
END $$;

-- (2) reach now traverses the participant-created edges transitively: A reaches {B, C}.
DO $$
DECLARE res jsonb; P text := 'https://conceptkernel.org/ontology/v3.8/core#link';
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', jsonb_build_object('from','urn:ckp:s40/a','via',P));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's40 FAIL (2): reach not ok: %', res; END IF;
  IF NOT (res->'reached' @> '["urn:ckp:s40/b"]'::jsonb) THEN
    RAISE EXCEPTION 's40 FAIL (2): direct target B not reached (edge not materialized): %', res; END IF;
  IF NOT (res->'reached' @> '["urn:ckp:s40/c"]'::jsonb) THEN
    RAISE EXCEPTION 's40 FAIL (2): transitive target C not reached: %', res; END IF;
END $$;

-- (3) a bare (non-IRI) endpoint seals the Edge instance but is honestly flagged not-traversable.
DO $$
DECLARE res jsonb; P text := 'https://conceptkernel.org/ontology/v3.8/core#link';
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('edge.create', jsonb_build_object('source','task-bare-1','predicate',P,'target','task-bare-2'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's40 FAIL (3): edge with bare ids not sealed: %', res; END IF;
  IF (res->>'reachable') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's40 FAIL (3): bare-id edge should be reachable:false (no quad): %', res; END IF;
END $$;

\echo s40_reach_edge_materialization: PASS
