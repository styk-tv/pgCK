-- s54_query_key_resolution.sql — pgCK#6.
--
-- ckp.query must resolve a filter key against the ACTUAL instance-body keys (jsonb,
-- project-independent), so a filtered read works even when the type resolves UNSHAPED
-- (e.g. the shape isn't in the session's project graph — the real trigger), and it must
-- NEVER silently return [] when the key can't be resolved. Self-contained: an unshaped
-- type whose bodies key properties by FULL IRI is exactly what create_typed writes and
-- exactly the path a project mismatch falls into.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

INSERT INTO ckp.instances(id, body) VALUES
  ('s54-1', '{"type":"urn:test:S","urn:test:prop/label":"hello","urn:test:prop/kind":"a"}'::jsonb),
  ('s54-2', '{"type":"urn:test:S","urn:test:prop/label":"hello","urn:test:prop/kind":"b"}'::jsonb),
  ('s54-3', '{"type":"urn:test:S","urn:test:prop/label":"other","urn:test:prop/kind":"c"}'::jsonb)
ON CONFLICT (id) DO UPDATE SET body=EXCLUDED.body;

-- (1) THE BUG: filter by localname on a full-IRI body — must resolve → 2 (was silently []).
--     Via the governed dispatch under the role floor (the real client path).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.query','{"type":"urn:test:S","filter":[{"key":"label","op":"eq","value":"hello"}]}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's54 FAIL: query not ok: %', res; END IF;
  IF (res->>'count')::int <> 2 THEN RAISE EXCEPTION 's54 FAIL: localname filter on full-IRI body expected 2, got % (%)', res->>'count', res; END IF;
  RAISE NOTICE 's54 PASS: unshaped full-IRI body — localname filter resolves (count=%)', res->>'count';
END $$;

-- (2) filter by the FULL IRI also resolves → 2.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.query('{"type":"urn:test:S","filter":[{"key":"urn:test:prop/label","op":"eq","value":"hello"}]}'::jsonb);
  IF (res->>'count')::int <> 2 THEN RAISE EXCEPTION 's54 FAIL: full-IRI filter key expected 2, got % (%)', res->>'count', res; END IF;
  RAISE NOTICE 's54 PASS: full-IRI filter key resolves (count=%)', res->>'count';
END $$;

-- (3) NEVER a silent []: a key that maps to no stored property → typed unresolved_shape.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.query('{"type":"urn:test:S","filter":[{"key":"nope","op":"eq","value":"x"}]}'::jsonb);
  IF (res->>'error') IS DISTINCT FROM 'unresolved_shape' THEN RAISE EXCEPTION 's54 FAIL: unresolvable key must be unresolved_shape, got %', res; END IF;
  RAISE NOTICE 's54 PASS: unresolvable key fails loud (error=%)', res->>'error';
END $$;
