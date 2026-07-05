-- s56_transition_project_robust.sql — pgCK#7 regression.
--
-- ckp.transition must resolve the instance type's sealed transition map INDEPENDENT of the
-- session ckp.project. The map is sealed in whatever kernel governs the type; a session default
-- must not decide which kernel's rules apply to an instance. Covers: (1) matching project,
-- (2) mismatched project (the fix — was invalid_transition), (3) a genuinely-illegal transition
-- still denied (no over-permitting / no default-allow).
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- seal a pending->sealed map for urn:t:Thing into the demo kernel graph (as apply does)
SELECT pgrdf.parse_turtle(
  '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .' || chr(10) ||
  '<urn:t:Thing> ckp:allowsTransition [ ckp:fromState "pending" ; ckp:toState "sealed" ] .',
  pgrdf.add_graph('urn:ckp:demo/kernel/ck'), 'https://conceptkernel.org/ontology/v3.8/core#');

-- (1) matching project: transition permitted (baseline)
DO $$
DECLARE res jsonb;
BEGIN
  PERFORM ckp.seal('s56-1','{"type":"urn:t:Thing","https://conceptkernel.org/ontology/v3.7/lifecycle_state":"pending"}'::jsonb);
  PERFORM set_config('ckp.project','demo',true);
  res := ckp.transition('{"id":"s56-1","to_state":"sealed"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's56 FAIL: matching-project transition should succeed, got %', res; END IF;
  RAISE NOTICE 's56 PASS: matching project transition ok (source=%)', res->>'source';
END $$;

-- (2) MISMATCHED project: same sealed map, must STILL resolve (the #7 fix)
DO $$
DECLARE res jsonb;
BEGIN
  PERFORM ckp.seal('s56-2','{"type":"urn:t:Thing","https://conceptkernel.org/ontology/v3.7/lifecycle_state":"pending"}'::jsonb);
  PERFORM set_config('ckp.project','some-other-project',true);
  res := ckp.transition('{"id":"s56-2","to_state":"sealed"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's56 FAIL: mismatched-project transition should STILL succeed (project-robust map), got %', res; END IF;
  RAISE NOTICE 's56 PASS: mismatched project transition ok — map resolved project-independently (source=%)', res->>'source';
END $$;

-- (3) genuinely-illegal transition (pending->deployed, not in the map) → still invalid_transition
DO $$
DECLARE res jsonb;
BEGIN
  PERFORM ckp.seal('s56-3','{"type":"urn:t:Thing","https://conceptkernel.org/ontology/v3.7/lifecycle_state":"pending"}'::jsonb);
  PERFORM set_config('ckp.project','demo',true);
  res := ckp.transition('{"id":"s56-3","to_state":"deployed"}'::jsonb);
  IF (res->>'error') IS DISTINCT FROM 'invalid_transition' THEN RAISE EXCEPTION 's56 FAIL: illegal transition must be denied, got %', res; END IF;
  RAISE NOTICE 's56 PASS: illegal transition still denied (%)', res->>'error';
END $$;
