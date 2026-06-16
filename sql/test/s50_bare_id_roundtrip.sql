-- s50_bare_id_roundtrip.sql — v0.4.14 (id-form): the bare-id link->reach round-trip.
--
-- create returns a BARE id; the client links + reaches by that bare id. Before v0.4.14 reach
-- SPARQL-parse-errored on the bare (relative) id and materialize_edge wrote no quad (reachable:false)
-- — so the round-trip the client actually uses was DEAD (CSVC routed around it via notify). Now reach
-- + materialize_edge both resolve the bare id to its @id, so link(A_bare,pred,B_bare) materializes
-- (reachable:true) and reach(from=A_bare,via=pred) reaches B's @id. This is the test s40 should have
-- had — s40 only ever fed full IRIs and even codified the bare-id break as expected reachable:false.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
DO $setup$ DECLARE g bigint; BEGIN g := pgrdf.add_graph('urn:ckp:s50-reach/kernel/ck'); PERFORM pgrdf.clear_graph(g); END $setup$;
SET ckp.project = 's50-reach';   -- no declared predicates -> namespace-allowlist fallback for the predicate

-- (1) create two real instances; capture their BARE ids (the form create returns).
DO $mk$
DECLARE a jsonb; b jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  a := ckp.dispatch('instance.create', '{"type":"urn:ckp:s50-reach/type/Node","label":"A"}'::jsonb);
  b := ckp.dispatch('instance.create', '{"type":"urn:ckp:s50-reach/type/Node","label":"B"}'::jsonb);
  RESET ROLE;
  IF (a->>'ok') IS DISTINCT FROM 'true' OR (b->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's50 FAIL (1): create failed: a=% b=%', a, b; END IF;
  IF position(':' in (a->>'id')) > 0 THEN RAISE EXCEPTION 's50 FAIL (1): create id should be BARE: %', a->>'id'; END IF;
  PERFORM set_config('s50.a', a->>'id', false);
  PERFORM set_config('s50.b', b->>'id', false);
END $mk$;

-- (2) link A->B by BARE id over a core predicate -> materializes a traversable quad (reachable:true).
DO $lnk$
DECLARE r jsonb; P text := 'https://conceptkernel.org/ontology/v3.8/core#link';
BEGIN
  SET LOCAL ROLE ck_participant;
  r := ckp.dispatch('instance.link', jsonb_build_object(
        'source', current_setting('s50.a'), 'predicate', P, 'target', current_setting('s50.b')));
  RESET ROLE;
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's50 FAIL (2): bare-id link rejected: %', r; END IF;
  IF (r->>'reachable') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's50 FAIL (2): bare-id link should MATERIALIZE (reachable:true) — the id-form fix: %', r; END IF;
END $lnk$;

-- (3) reach from A by BARE id reaches B's @id (the round-trip the client actually uses).
DO $rch$
DECLARE res jsonb; P text := 'https://conceptkernel.org/ontology/v3.8/core#link'; b_iri text;
BEGIN
  b_iri := ckp._resolve_ref(current_setting('s50.b'));   -- B's stamped @id
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', jsonb_build_object('from', current_setting('s50.a'), 'via', P));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's50 FAIL (3): reach not ok: %', res; END IF;
  IF NOT (res->'reached' @> jsonb_build_array(b_iri)) THEN
    RAISE EXCEPTION 's50 FAIL (3): bare-id reach should reach B (%) — round-trip was dead before v0.4.14: %', b_iri, res; END IF;
END $rch$;

\echo s50_bare_id_roundtrip: PASS
