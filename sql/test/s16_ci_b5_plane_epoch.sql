-- s16_ci_b5_plane_epoch.sql — CI-B-5 (SPEC.ROADMAP.v3.9.CHECKLIST index 20).
--
-- The ckp:plane + ckp:epoch ontology delta on ckp:Affordance (v3.9 §9). Confirms: the
-- extended core.ttl declares both terms; an affordance carrying plane=instance + epoch
-- conforms to AffordanceShape; an out-of-enum plane is rejected (sh:in bites); and
-- shapes_self_test still passes (the delta didn't disturb TaskShape/GoalShape).
--
-- Run (booted + kernel loaded by the smoke): psql … < s16_ci_b5_plane_epoch.sql

\set ON_ERROR_STOP 1

-- (a) the new terms are declared in the loaded core ontology (graph urn:ckp:core).
DO $$
DECLARE v_ask text;
BEGIN
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask FROM pgrdf.sparql(
    'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
     PREFIX owl: <http://www.w3.org/2002/07/owl#>
     ASK FROM <urn:ckp:core>
     WHERE { ckp:plane a owl:DatatypeProperty . ckp:epoch a owl:DatatypeProperty . }') j LIMIT 1;
  IF COALESCE(v_ask, 'false') <> 'true' THEN
    RAISE EXCEPTION 's16 FAIL: ckp:plane / ckp:epoch not declared in core ontology (ask=%)', v_ask;
  END IF;
END $$;

-- (b) an affordance carrying plane=instance + epoch CONFORMS to AffordanceShape.
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
<urn:ckp:aff:s16-ok> a ckp:Affordance ;
  ckp:inTopic "input.kernel.pgCK.action.s16" ;
  ckp:plane "instance" ;
  ckp:epoch "1"^^xsd:integer .';
BEGIN
  IF NOT ckp.validate(ttl, v_core) THEN
    RAISE EXCEPTION 's16 FAIL: a plane=instance / epoch=1 affordance did NOT conform to AffordanceShape';
  END IF;
END $$;

-- (c) an out-of-enum plane is REJECTED (the sh:in (instance governance) constraint bites).
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:aff:s16-bad> a ckp:Affordance ;
  ckp:inTopic "input.kernel.pgCK.action.s16bad" ;
  ckp:plane "bogus" .';
BEGIN
  IF ckp.validate(ttl, v_core) THEN
    RAISE EXCEPTION 's16 FAIL: out-of-enum plane="bogus" wrongly CONFORMED (sh:in not enforced)';
  END IF;
END $$;

-- (d) shapes_self_test still passes (raises if TaskShape/GoalShape missing).
SELECT ckp.shapes_self_test('demo');

\echo s16_ci_b5_plane_epoch: PASS
