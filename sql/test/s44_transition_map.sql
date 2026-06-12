-- s44_transition_map.sql — v0.5 roadmap T3: the per-kernel sealed transition map.
--
-- An adopter governs a Ship lifecycle and proves the map is the KERNEL's, not a global:
--   (1) govern-set a Ship map (planned→[crewed], crewed→[deployed]) — applied to the kernel graph;
--   (2) a legal transition (planned→crewed) succeeds, source=kernel;
--   (3) THE KEYSTONE — an illegal transition (planned→deployed, not in the map) is rejected;
--   (4) NO GLOBAL BLEED — a Task (no sealed map) uses the GLOBAL config: planned→in_progress works
--       (source=config), but Task→crewed (a Ship-map-only state) is rejected.
--
-- Run (booted by the smoke): psql … < s44_transition_map.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- ensure this project's kernel graph exists + empty (the governance apply populates it).
DO $setup$ DECLARE g bigint; BEGIN g := pgrdf.add_graph('urn:ckp:s44-test/kernel/ck'); PERFORM pgrdf.clear_graph(g); END $setup$;

SET ckp.project = 's44-test';

-- (1) govern-set the Ship transition map.
DO $$
DECLARE pr jsonb; ap jsonb; piri text;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','set_transition_map', 'about','urn:ckp:s44-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('targetClass','urn:ckp:s44-test/type/Ship',
      'map', jsonb_build_object('planned', jsonb_build_array('crewed'),
                                'crewed',  jsonb_build_array('deployed')))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's44 FAIL (1): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's44 FAIL (1): apply rejected: %', ap; END IF;
  IF (ap#>>'{applied,graph_changed}') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's44 FAIL (1): transition map not applied to the kernel graph: %', ap; END IF;
END $$;

-- two ships (lifecycle defaults to 'planned'; generic create sets no lifecycle_state).
DO $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  r := ckp.dispatch('instance.create','{"type":"urn:ckp:s44-test/type/Ship","name":"Endeavour"}'::jsonb);
  PERFORM set_config('s44.ship1', r->>'id', false);
  r := ckp.dispatch('instance.create','{"type":"urn:ckp:s44-test/type/Ship","name":"Defiant"}'::jsonb);
  PERFORM set_config('s44.ship2', r->>'id', false);
  RESET ROLE;
END $$;

-- (2) legal transition planned→crewed via the sealed kernel map.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', current_setting('s44.ship1'), 'to_state','crewed'));
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's44 FAIL (2): planned->crewed rejected: %', res; END IF;
  IF res->>'source' <> 'kernel' THEN RAISE EXCEPTION 's44 FAIL (2): should use the kernel sealed map (source=kernel), got %: %', res->>'source', res; END IF;
  IF res->>'from' <> 'planned' THEN RAISE EXCEPTION 's44 FAIL (2): from should be planned: %', res; END IF;
END $$;

-- (3) THE KEYSTONE: planned→deployed is NOT in the map → rejected by the kernel map.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', current_setting('s44.ship2'), 'to_state','deployed'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_transition' THEN RAISE EXCEPTION 's44 FAIL (3): planned->deployed (not in map) NOT rejected: %', res; END IF;
  IF res->>'source' <> 'kernel' THEN RAISE EXCEPTION 's44 FAIL (3): rejection should be by the kernel map: %', res; END IF;
END $$;

-- (4) NO GLOBAL BLEED: a Task (no sealed map) uses the GLOBAL config.
DO $$
DECLARE r jsonb; res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  r := ckp.dispatch('instance.create','{"task":{"target_kernel":"s44","title":"patrol"}}'::jsonb);
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', r->>'id', 'to_state','in_progress'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's44 FAIL (4): Task planned->in_progress (global) rejected: %', res; END IF;
  IF res->>'source' <> 'config' THEN RAISE EXCEPTION 's44 FAIL (4): Task should use the global config map (source=config), got %: %', res->>'source', res; END IF;
  r := ckp.dispatch('instance.create','{"task":{"target_kernel":"s44","title":"patrol2"}}'::jsonb);
  res := ckp.dispatch('instance.transition', jsonb_build_object('id', r->>'id', 'to_state','crewed'));
  RESET ROLE;
  IF res->>'error' <> 'invalid_transition' THEN
    RAISE EXCEPTION 's44 FAIL (4): Task->crewed should be rejected — the Ship map must NOT bleed to Task: %', res; END IF;
END $$;

\echo s44_transition_map: PASS
