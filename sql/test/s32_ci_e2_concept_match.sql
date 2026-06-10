-- s32_ci_e2_concept_match.sql — CI-E-2 (SPEC.ROADMAP.v3.9.CHECKLIST index 2).
--
-- concept.match (governed query affordance) + instance.explain. Confirms: a label search returns
-- ranked candidates (exact > prefix > contains); a SQL-injection term is bound (matches nothing —
-- never injects); an empty term is rejected; instance.explain reports the direct-vs-inferred
-- materialization summary (full derivation chain deferred).
--
-- Run (booted by the smoke): psql … < s32_ci_e2_concept_match.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

INSERT INTO ckp.instances(id, body) VALUES
  ('urn:cm:1', '{"type":"urn:test:Concept","rdfs:label":"redx"}'::jsonb),
  ('urn:cm:2', '{"type":"urn:test:Concept","rdfs:label":"redx widget"}'::jsonb),
  ('urn:cm:3', '{"type":"urn:test:Concept","rdfs:label":"the redx car"}'::jsonb)
ON CONFLICT (id) DO UPDATE SET body=EXCLUDED.body;

-- (a) ranked label search: exact (redx) first, then prefix, then contains.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', '{"term":"redx"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's32 FAIL: concept.match not ok: %', res; END IF;
  IF (res->>'count')::int <> 3 THEN RAISE EXCEPTION 's32 FAIL: count=% (want 3): %', res->>'count', res; END IF;
  IF res->'candidates'->0->>'label' <> 'redx' THEN RAISE EXCEPTION 's32 FAIL: top candidate not exact match: %', res->'candidates'->0; END IF;
END $$;

-- (b) a SQL-injection term is bound (plpgsql) — matches nothing, never dumps the table.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', jsonb_build_object('term', 'redx'' OR ''1''=''1'));
  RESET ROLE;
  IF (res->>'count')::int <> 0 THEN RAISE EXCEPTION 's32 FAIL: injection term matched % (NOT bound)', res->>'count'; END IF;
END $$;

-- (c) an empty term is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('concept.match', '{"term":""}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'invalid_term' THEN RAISE EXCEPTION 's32 FAIL: empty term not rejected: %', res; END IF;
END $$;

-- (d) instance.explain reports the direct-vs-inferred materialization summary.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.explain', '{"id":"urn:cm:1"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's32 FAIL: explain not ok: %', res; END IF;
  IF res->'materialization' IS NULL THEN RAISE EXCEPTION 's32 FAIL: no materialization summary: %', res; END IF;
END $$;

\echo s32_ci_e2_concept_match: PASS
