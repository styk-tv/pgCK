-- s39_graph_apply_type_evolution.sql — Tier 2 (2/3): the governance EFFECT.
--
-- The exit test for ckp.apply's _graph_apply: a kernel's TYPE actually changes via
-- consensus. Before v0.4.5, apply bumped the epoch + sealed "applied" but the shape
-- never moved. Here we prove the full loop end to end:
--   (1) create a Ship — seals, because Ship is unshaped (no required props yet);
--   (2) propose + vote + apply add_property(crew_size, minCount 1) for the Ship class —
--       the op is translated to SHACL, meta-fenced, and copied into the kernel graph;
--   (3) THE KEYSTONE — the SAME create (no crew_size) is now REJECTED: the type changed;
--   (4) a Ship WITH crew_size seals again.
-- Everything goes through ckp.dispatch; the typed creates run as a real ck_participant.
--
-- Run (booted by the smoke): psql … < s39_graph_apply_type_evolution.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- Ensure this project's kernel graph exists and starts EMPTY (Ship unshaped).
DO $setup$
DECLARE g bigint;
BEGIN
  g := pgrdf.add_graph('urn:ckp:s39-test/kernel/ck');
  PERFORM pgrdf.clear_graph(g);
END $setup$;

SET ckp.project = 's39-test';

-- (1) BASELINE — a Ship seals while the type carries no required props.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:s39-test/type/Ship","name":"Voyager"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's39 FAIL (1): baseline Ship create (unshaped) rejected: %', res; END IF;
END $$;

-- (2) GOVERN — propose + vote + apply add_property(crew_size, minCount 1) on the Ship class.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_property', 'about','urn:ckp:s39-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object(
      'targetClass','urn:ckp:s39-test/type/Ship',
      'path','urn:ckp:s39-test/prop/crew_size',
      'minCount',1)));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's39 FAIL (2): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';

  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value', 'approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's39 FAIL (2): vote rejected: %', vt; END IF;

  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's39 FAIL (2): apply rejected: %', ap; END IF;
  IF (ap->>'state') <> 'applied' THEN RAISE EXCEPTION 's39 FAIL (2): proposal not applied: %', ap; END IF;
  -- the EFFECT: apply reports the kernel graph actually changed.
  IF (ap#>>'{applied,graph_changed}') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's39 FAIL (2): apply did NOT mutate the kernel graph (graph_changed != true): %', ap; END IF;
END $$;

-- (2b) the constraint is now a fact in the kernel graph: crew_size is a required prop of Ship.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pgrdf.sparql($q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?prop WHERE { GRAPH <urn:ckp:s39-test/kernel/ck> {
      ?s sh:targetClass <urn:ckp:s39-test/type/Ship> ; sh:property ?prop .
      ?prop sh:path <urn:ckp:s39-test/prop/crew_size> ; sh:minCount ?n . FILTER(?n >= 1) } }
  $q$) j;
  IF n < 1 THEN RAISE EXCEPTION 's39 FAIL (2b): crew_size not present as a required prop after apply'; END IF;
END $$;

-- (3) THE KEYSTONE — the SAME create that seal'd in (1) is now REJECTED. The type changed
--     via consensus, and the gate enforces it on the very next seal.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:s39-test/type/Ship","name":"Defiant"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's39 FAIL (3): a Ship missing the GOVERNED-IN crew_size was NOT rejected — apply did not change the type: %', res; END IF;
  IF res->>'error' NOT LIKE '%required%' AND res->>'error' NOT LIKE '%kernel shape%' THEN
    RAISE EXCEPTION 's39 FAIL (3): rejected, but not for the new shape constraint: %', res; END IF;
END $$;

-- (4) a Ship WITH the now-required crew_size seals again.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:s39-test/type/Ship","name":"Endeavour","crew_size":9}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's39 FAIL (4): Ship WITH crew_size still rejected: %', res; END IF;
  IF (res->>'verified') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's39 FAIL (4): Ship sealed but not verified: %', res; END IF;
END $$;

\echo s39_graph_apply_type_evolution: PASS
