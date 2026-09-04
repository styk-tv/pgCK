-- s90 — THE CENSUS MUST FLAG A DANGLING TARGET PROJECT, NOT ONLY A DANGLING MODULE
--
-- 0.4.111. `fleet.adoptions` has flagged `malformed` since 0.4.68 (the ADOPTS IRI
-- names no non-empty graph). The mirror case went unreported: the module resolves
-- and `intoProject` names a project with NO graphs at all, so the adoption is
-- sealed, judged, four-stamped — and reachable by no composed surface.
--
-- Measured origin (ck-allinone v0.7.44, virgin floor): the bundle's init.sql
-- hardcodes urn:ckp:project:demo while bootstrap_kernel follows the configured
-- ckp.project, so a deployment that names its kernel loads 852 quads of law that
-- its own surface cannot reach — and the census called it healthy.
--
-- THE NEGATIVE CONTROL IS THE POINT: a check that cannot distinguish the two
-- cases is not a check. (a) is the defect, (b) is a real adoption that must stay
-- unflagged, (c) proves the flag is independent of `malformed`, (d) proves all
-- four intoProject spellings reduce to the same segment.
\set ON_ERROR_STOP on
DO $$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  res jsonb; v_orph boolean; v_mal boolean; v_count int;
BEGIN
  PERFORM set_config('ckp.project', 'demo', false);
  -- A test declares its identity like any other caller: the substrate refuses an
  -- unattributed write, and a fact belonging to nobody is permanent.
  PERFORM set_config('ckp.requester', 'svc:s90-smoke', true);

  -- (a) THE DEFECT — a real module adopted into a project that has no graphs.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type', N||'Adoption', '@id', 'urn:s90:adoption-nowhere',
    N||'adopts',       'urn:ckp:core',
    N||'intoProject',  'urn:ckp:project:s90-nowhere',
    N||'sourceDigest', repeat('a',64),
    N||'intoEpoch',    0));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's90 FAIL (a): the orphaning adoption should SEAL — it is well-formed; the census reports it, the gate does not refuse it: %', res; END IF;

  -- (b) THE NEGATIVE CONTROL — the same module into a project that DOES have graphs.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type', N||'Adoption', '@id', 'urn:s90:adoption-home',
    N||'adopts',       'urn:ckp:core',
    N||'intoProject',  'urn:ckp:project:demo',
    N||'sourceDigest', repeat('b',64),
    N||'intoEpoch',    0));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's90 FAIL (b): a legitimate adoption was refused: %', res; END IF;

  res := ckp.dispatch('fleet.adoptions', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's90 FAIL: fleet.adoptions: %', res; END IF;

  -- (a) must be flagged orphaned, and NOT malformed (the module is real).
  SELECT (r->>'orphaned')::boolean, (r->>'malformed')::boolean INTO v_orph, v_mal
    FROM jsonb_array_elements(res->'adoptions') r
   WHERE r->>'intoProject' = 'urn:ckp:project:s90-nowhere';
  IF v_orph IS NULL THEN
    RAISE EXCEPTION 's90 FAIL (a): fleet.adoptions carries no `orphaned` key — the flag does not exist'; END IF;
  IF NOT v_orph THEN
    RAISE EXCEPTION 's90 FAIL (a): an adoption into a project with NO graphs read orphaned=false — the census still calls a broken install healthy'; END IF;
  -- (c) the two flags are independent: this one is orphaned but NOT malformed.
  IF v_mal THEN
    RAISE EXCEPTION 's90 FAIL (c): orphaned row also read malformed=true — the module urn:ckp:core resolves; the flags are being conflated'; END IF;

  -- (b) must NOT be flagged — this is what makes the check falsifiable.
  SELECT (r->>'orphaned')::boolean INTO v_orph
    FROM jsonb_array_elements(res->'adoptions') r
   WHERE r->>'intoProject' = 'urn:ckp:project:demo' AND r->>'adopts' = 'urn:ckp:core';
  IF v_orph IS DISTINCT FROM false THEN
    RAISE EXCEPTION 's90 FAIL (b): a legitimate adoption into a project WITH graphs read orphaned=% — a flag that fires on everything reports nothing', v_orph; END IF;

  SELECT (res->>'orphanedCount')::int INTO v_count;
  IF v_count IS NULL OR v_count < 1 THEN
    RAISE EXCEPTION 's90 FAIL: orphanedCount is % — the summary must count what the rows flag', v_count; END IF;

  RAISE NOTICE 's90 (a-c) PASS — a dangling TARGET project is flagged, a real one is not, and orphaned is independent of malformed (orphanedCount=%)', v_count;
END $$;

-- (d) all four intoProject spellings reduce to one segment, so the flag cannot be
--     dodged by writing the same project a different way.
DO $$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  res jsonb; spell text; v_orph boolean; i int := 0;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s90-smoke', true);
  FOREACH spell IN ARRAY ARRAY['urn:ckp:demo', 'urn:ckp:demo/kernel/ck', 'urn:ckp:project/demo'] LOOP
    i := i + 1;
    res := ckp.dispatch('instance.create', jsonb_build_object(
      'type', N||'Adoption', '@id', 'urn:s90:spell-'||i,
      N||'adopts',       'urn:ckp:core',
      N||'intoProject',  spell,
      N||'sourceDigest', repeat('c',64),
      N||'intoEpoch',    0));
    IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's90 FAIL (d): seal % refused: %', spell, res; END IF;
  END LOOP;

  res := ckp.dispatch('fleet.adoptions', '{}'::jsonb);
  FOREACH spell IN ARRAY ARRAY['urn:ckp:demo', 'urn:ckp:demo/kernel/ck', 'urn:ckp:project/demo'] LOOP
    SELECT (r->>'orphaned')::boolean INTO v_orph
      FROM jsonb_array_elements(res->'adoptions') r WHERE r->>'intoProject' = spell;
    IF v_orph IS DISTINCT FROM false THEN
      RAISE EXCEPTION 's90 FAIL (d): spelling % read orphaned=% — demo HAS graphs; the segment reduction missed a spelling', spell, v_orph; END IF;
  END LOOP;
  RAISE NOTICE 's90 (d) PASS — all four intoProject spellings reduce to the same segment';
END $$;

SELECT 's90 PASS — the census flags a dangling target project, spares a real one, and cannot be dodged by spelling' AS result;
