-- s29_ci_e5_typed_query.sql — CI-E-5 (SPEC.ROADMAP.v3.9.CHECKLIST index 5).
--
-- instance.query — the typed derived-QueryShape read. Confirms: eq + numeric filters return the
-- right rows; an out-of-enum operator and an injection-shaped filter key are rejected; a
-- SQL-injection VALUE is quote_literal-escaped (matches nothing — never dumps the table); the
-- legacy instances.count alias still works.
--
-- Run (booted by the smoke): psql … < s29_ci_e5_typed_query.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

INSERT INTO ckp.instances(id, body) VALUES
  ('urn:e:1', '{"type":"urn:test:E","color":"red","rank":"3"}'::jsonb),
  ('urn:e:2', '{"type":"urn:test:E","color":"blue","rank":"7"}'::jsonb),
  ('urn:e:3', '{"type":"urn:test:E","color":"red","rank":"9"}'::jsonb)
ON CONFLICT (id) DO UPDATE SET body=EXCLUDED.body;

-- (a) eq filter via instance.query through the dispatch.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query', '{"type":"urn:test:E","filter":[{"key":"color","op":"eq","value":"red"}]}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's29 FAIL: query not ok: %', res; END IF;
  IF (res->>'count')::int <> 2 THEN RAISE EXCEPTION 's29 FAIL: eq color=red count=% (want 2)', res->>'count'; END IF;
END $$;

-- (b) numeric gt filter (regex-guarded cast).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query', '{"type":"urn:test:E","filter":[{"key":"rank","op":"gt","value":"5"}]}'::jsonb);
  RESET ROLE;
  IF (res->>'count')::int <> 2 THEN RAISE EXCEPTION 's29 FAIL: rank>5 count=% (want 2)', res->>'count'; END IF;
END $$;

-- (c) an out-of-enum operator is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query', '{"type":"urn:test:E","filter":[{"key":"color","op":"regexp","value":".*"}]}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'invalid_operator' THEN RAISE EXCEPTION 's29 FAIL: out-of-enum op not rejected: %', res; END IF;
END $$;

-- (d) a SQL-injection VALUE is quote_literal-escaped — matches nothing, never dumps the table.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query', jsonb_build_object('type','urn:test:E',
           'filter', jsonb_build_array(jsonb_build_object('key','color','op','eq','value','red'' OR ''1''=''1'))));
  RESET ROLE;
  IF (res->>'count')::int <> 0 THEN RAISE EXCEPTION 's29 FAIL: injection value returned % rows — NOT escaped!', res->>'count'; END IF;
END $$;

-- (e) an injection-shaped filter key is rejected by the key gate.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query', jsonb_build_object('type','urn:test:E',
           'filter', jsonb_build_array(jsonb_build_object('key','color OR 1=1','op','eq','value','y'))));
  RESET ROLE;
  IF res->>'error' <> 'invalid_filter_key' THEN RAISE EXCEPTION 's29 FAIL: injection key not rejected: %', res; END IF;
END $$;

-- (f) the legacy instances.count alias still works (alias window unaffected).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instances.count', '{}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's29 FAIL: legacy instances.count broke: %', res; END IF;
END $$;

\echo s29_ci_e5_typed_query: PASS
