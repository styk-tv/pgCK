-- s57_create_typed_core_lifecycle.sql — create_typed must file recognized v3.7 CORE lifecycle
-- keys (lifecycle_state) under the v3.7 core NS the transition gate + task.create read/write,
-- NOT the type namespace. Otherwise instance.create {lifecycle_state:'pending'} lands where
-- nothing reads it, the instance is silently treated as 'planned', and a pending→sealed map then
-- (correctly) denies planned→sealed. End-to-end regression for the create→transition seal path.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- a pending→sealed transition map for the type (sealed in the demo kernel graph)
SELECT pgrdf.parse_turtle(
  '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .' || chr(10) ||
  '<urn:ckp:demo/type/Thing> ckp:allowsTransition [ ckp:fromState "pending" ; ckp:toState "sealed" ] .',
  pgrdf.add_graph('urn:ckp:demo/kernel/ck'), 'https://conceptkernel.org/ontology/v3.8/core#');

-- (1) create with lifecycle_state:'pending' → must land under the v3.7 core NS as pending
DO $$
DECLARE res jsonb; v_id text; core_state text;
BEGIN
  res := ckp.dispatch('instance.create','{"type":"urn:ckp:demo/type/Thing","lifecycle_state":"pending","label":"x"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's57 FAIL: create not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'https://conceptkernel.org/ontology/v3.7/lifecycle_state' INTO core_state FROM ckp.instances WHERE id = v_id;
  IF core_state IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 's57 FAIL: lifecycle_state must land under the v3.7 core NS as pending, got % (body=%)',
      core_state, (SELECT body FROM ckp.instances WHERE id=v_id);
  END IF;
  RAISE NOTICE 's57 PASS: create_typed files lifecycle_state under the v3.7 core NS (%)', core_state;
END $$;

-- (2) end-to-end: create(pending) → transition(pending→sealed) succeeds (was invalid_transition)
DO $$
DECLARE res jsonb; v_id text; tr jsonb;
BEGIN
  res := ckp.dispatch('instance.create','{"type":"urn:ckp:demo/type/Thing","lifecycle_state":"pending","label":"y"}'::jsonb);
  v_id := res->>'id';
  PERFORM set_config('ckp.project','demo',true);
  tr := ckp.transition(jsonb_build_object('id', v_id, 'to_state', 'sealed'));
  IF (tr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's57 FAIL: create(pending)→transition(sealed) should succeed, got %', tr; END IF;
  IF (tr->>'from') IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 's57 FAIL: transition should see from=pending, got from=% (%)', tr->>'from', tr; END IF;
  RAISE NOTICE 's57 PASS: create(pending) → transition(sealed) end-to-end ok (from=%)', tr->>'from';
END $$;
