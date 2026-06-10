-- s17_ci_b4_registry.sql — CI-B-4 (SPEC.ROADMAP.v3.9.CHECKLIST index 19).
--
-- The exact-match sealed registry. Seeds three affordance facts (instance / governance /
-- delegate), rebuilds the index from them, and proves: known verbs resolve to their row
-- (carrying plane / epoch / delegate); an unknown verb returns NULL (the basis for
-- {ok:false, error:'unknown_affordance'}); delegation is a sealed fact, not an absence.
--
-- Run (booted by the smoke): psql … < s17_ci_b4_registry.sql

\set ON_ERROR_STOP 1

-- Seed three test affordances into a scratch graph (instance / governance / delegate).
DO $$
DECLARE
  v_g bigint;
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
<urn:ckp:aff:s17-read> a ckp:Affordance ;
  ckp:inTopic "input.kernel.TestK.action.thing.read" ;
  ckp:plane "instance" ; ckp:epoch "2"^^xsd:integer .
<urn:ckp:aff:s17-propose> a ckp:Affordance ;
  ckp:inTopic "input.kernel.TestK.action.type.propose" ;
  ckp:plane "governance" .
<urn:ckp:aff:s17-tool> a ckp:Affordance ;
  ckp:inTopic "input.kernel.TestK.action.tool.run" ;
  ckp:delegate "true"^^xsd:boolean .';
BEGIN
  v_g := pgrdf.add_graph('urn:ckp:s17-registry');
  PERFORM pgrdf.clear_graph(v_g);
  PERFORM pgrdf.parse_turtle(ttl, v_g, 'urn:ckp:s17#');
END $$;

-- Rebuild the registry from the sealed affordance facts.
DO $$
DECLARE n int;
BEGIN
  n := ckp.registry_refresh();
  IF n < 3 THEN RAISE EXCEPTION 's17 FAIL: registry_refresh indexed % affordances (< 3)', n; END IF;
END $$;

-- (a) instance-plane verb resolves with its plane + epoch.
DO $$
DECLARE v_row jsonb;
BEGIN
  v_row := ckp.registry_lookup('TestK', 'thing.read');
  IF v_row IS NULL THEN RAISE EXCEPTION 's17 FAIL: thing.read not found in registry'; END IF;
  IF v_row->>'plane' <> 'instance' THEN RAISE EXCEPTION 's17 FAIL: thing.read plane=% (want instance)', v_row->>'plane'; END IF;
  IF (v_row->>'epoch')::int <> 2 THEN RAISE EXCEPTION 's17 FAIL: thing.read epoch=% (want 2)', v_row->>'epoch'; END IF;
END $$;

-- (b) governance-plane verb resolves with plane=governance.
DO $$
DECLARE v_row jsonb;
BEGIN
  v_row := ckp.registry_lookup('TestK', 'type.propose');
  IF v_row IS NULL THEN RAISE EXCEPTION 's17 FAIL: type.propose not found'; END IF;
  IF v_row->>'plane' <> 'governance' THEN RAISE EXCEPTION 's17 FAIL: type.propose plane=% (want governance)', v_row->>'plane'; END IF;
END $$;

-- (c) a sealed delegation fact resolves with delegate=true (distinct from absence).
DO $$
DECLARE v_row jsonb;
BEGIN
  v_row := ckp.registry_lookup('TestK', 'tool.run');
  IF v_row IS NULL THEN RAISE EXCEPTION 's17 FAIL: tool.run not found'; END IF;
  IF (v_row->>'delegate')::boolean IS NOT TRUE THEN RAISE EXCEPTION 's17 FAIL: tool.run delegate=% (want true)', v_row->>'delegate'; END IF;
END $$;

-- (d) an unknown verb returns NULL — the basis for unknown_affordance, NOT delegate.
DO $$
BEGIN
  IF ckp.registry_lookup('TestK', 'nope.missing') IS NOT NULL THEN
    RAISE EXCEPTION 's17 FAIL: unknown verb wrongly resolved (should be NULL)';
  END IF;
END $$;

\echo s17_ci_b4_registry: PASS
