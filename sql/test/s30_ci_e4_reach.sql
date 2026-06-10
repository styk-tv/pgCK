-- s30_ci_e4_reach.sql — CI-E-4 (SPEC.ROADMAP.v3.9.CHECKLIST index 4).
--
-- instance.reach — bounded transitive traversal. Confirms: a declared predicate traverses a
-- chain transitively (a → b → c reaches {b, c}); an undeclared/foreign predicate is rejected
-- (registry-checked, not parsed); an injection-shaped `via` is rejected; depth is reported as
-- the engine cap (pgrdf.path_max_depth).
--
-- Run (booted by the smoke): psql … < s30_ci_e4_reach.sql

\set ON_ERROR_STOP 1

-- seed a chain a → b → c via a conceptkernel predicate into a scratch graph.
DO $$
DECLARE v_g bigint;
BEGIN
  v_g := pgrdf.add_graph('urn:ckp:s30-reach');
  PERFORM pgrdf.clear_graph(v_g);
  PERFORM pgrdf.parse_turtle(
    '<urn:reach:a> <https://conceptkernel.org/ontology/v3.8/core#link> <urn:reach:b> .
     <urn:reach:b> <https://conceptkernel.org/ontology/v3.8/core#link> <urn:reach:c> .',
    v_g, 'urn:ckp:s30#');
END $$;

-- (a) a declared predicate reaches the transitive closure (b and c from a).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach',
    '{"from":"urn:reach:a","via":"https://conceptkernel.org/ontology/v3.8/core#link"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's30 FAIL: reach not ok: %', res; END IF;
  IF jsonb_array_length(res->'reached') <> 2 THEN RAISE EXCEPTION 's30 FAIL: reached % (want 2: b,c): %', jsonb_array_length(res->'reached'), res; END IF;
  IF NOT (res->'reached' @> '["urn:reach:c"]'::jsonb) THEN RAISE EXCEPTION 's30 FAIL: transitive node c not reached: %', res; END IF;
END $$;

-- (b) an undeclared / foreign predicate is rejected (registry-checked, never parsed).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', '{"from":"urn:reach:a","via":"http://evil.example/pwn"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'undeclared_predicate' THEN RAISE EXCEPTION 's30 FAIL: foreign predicate not rejected: %', res; END IF;
END $$;

-- (c) an injection-shaped `via` is rejected by the IRI gate.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', jsonb_build_object('from','urn:reach:a','via','urn:ckp:x> ?y . } UNION { ?a ?b ?c'));
  RESET ROLE;
  IF res->>'error' <> 'undeclared_predicate' THEN RAISE EXCEPTION 's30 FAIL: injection via not rejected: %', res; END IF;
END $$;

-- (d) the depth cap is reported (pgrdf.path_max_depth).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.reach', '{"from":"urn:reach:a","via":"https://conceptkernel.org/ontology/v3.8/core#link"}'::jsonb);
  RESET ROLE;
  IF (res->>'max_depth') IS NULL THEN RAISE EXCEPTION 's30 FAIL: max_depth not reported: %', res; END IF;
END $$;

\echo s30_ci_e4_reach: PASS
