-- s83_identity_and_attribution.sql — TWO INSTRUMENTS, EACH FALSIFIABLE (0.4.103).
--
-- C-17: the identity triple. Two live benches once reported ONE identical
-- build identifier while running TWO different binaries — the defect class
-- pgRDF says has only ever been caught by version() == build_id() ==
-- extversion. The verb must DETECT, not merely print three strings, and it
-- must REFUSE a verdict it cannot show.
--
-- C-12: per-kernel storage attribution. The report must attribute a KNOWN
-- fixture correctly, and shared weight (core, modules, scratch) must land in
-- a NAMED substrate bucket — never silently in somebody's column.
\set ON_ERROR_STOP 1

DO $$
DECLARE t jsonb; mis jsonb; unm jsonb; s jsonb; g bigint; e text;
BEGIN
  -- (a) the live triple is complete and its verdict matches a hand comparison.
  t := ckp.identity_triple();
  SELECT extversion INTO e FROM pg_extension WHERE extname='pgck';
  IF NOT (t ? 'version' AND t ? 'extversion' AND t ? 'build_id' AND t ? 'agreement') THEN
    RAISE EXCEPTION 's83 (a) FAIL — incomplete triple: %', t; END IF;
  IF (t->>'agreement')::boolean IS DISTINCT FROM (t->>'version' = e) THEN
    RAISE EXCEPTION 's83 (a) FAIL — verdict % disagrees with hand comparison of version=% extversion=%', t->>'agreement', t->>'version', e; END IF;
  RAISE NOTICE 's83 (a) PASS — triple complete (%/%/%), verdict % matches hand comparison',
    t->>'version', t->>'extversion', left(t->>'build_id',24), t->>'state';

  -- (b) CONTROL: a forced mismatch is DETECTED, naming both planes.
  mis := ckp._identity_agreement('0.0.1','0.0.2','s83');
  IF (mis->>'agreement')::boolean IS NOT FALSE OR mis->'divergence' IS NULL THEN
    RAISE EXCEPTION 's83 (b) FAIL — a mismatched pair was not detected: %', mis; END IF;
  RAISE NOTICE 's83 (b) PASS — a forced mismatch reports agreement:false naming both planes';

  -- (c) CONTROL: a missing plane REFUSES a verdict — never fabricates one.
  unm := ckp._identity_agreement(NULL, '0.0.2', 's83');
  IF unm->>'agreement' IS NOT NULL OR unm->>'state' IS DISTINCT FROM 'unmeasurable' THEN
    RAISE EXCEPTION 's83 (c) FAIL — a missing plane produced a verdict: %', unm; END IF;
  RAISE NOTICE 's83 (c) PASS — a missing plane refuses: agreement null, state unmeasurable';

  -- (d) per-kernel attribution against a KNOWN fixture.
  g := pgrdf.add_graph('urn:ckp:s83probe/fixture');
  s := ckp.storage();
  PERFORM pgrdf.drop_graph(g, false);
  IF COALESCE((s->'perKernel'->'s83probe'->>'graphs')::int,0) < 1 THEN
    RAISE EXCEPTION 's83 (d) FAIL — a graph created under urn:ckp:s83probe/ was not attributed to s83probe: %', s->'perKernel'; END IF;
  RAISE NOTICE 's83 (d) PASS — fixture graph attributed to its kernel: %', s->'perKernel'->'s83probe';

  -- (e) CONTROL: shared weight lands in the NAMED substrate bucket, and core
  -- is not attributed to any kernel.
  IF s->'perKernel'->'substrate' IS NULL THEN
    RAISE EXCEPTION 's83 (e) FAIL — no substrate bucket: shared graphs are attributed to kernels or dropped'; END IF;
  IF s->'perKernel' ? 'core' THEN
    RAISE EXCEPTION 's83 (e) FAIL — a bucket named core exists: urn:ckp:core leaked out of the substrate bucket'; END IF;
  RAISE NOTICE 's83 (e) PASS — substrate bucket present (%), core stays inside it', s->'perKernel'->'substrate'->>'graphs';

  -- (f) the instruments are door-reachable: surface.check carries both.
  s := ckp.surface_check();
  IF s->'engineIdentity' IS NULL OR s->'storage'->'perKernel' IS NULL THEN
    RAISE EXCEPTION 's83 (f) FAIL — surface.check does not carry engineIdentity + storage.perKernel: a check that is not a verb does not exist'; END IF;
  RAISE NOTICE 's83 (f) PASS — surface.check carries engineIdentity and storage.perKernel';
END $$;

\echo 's83 PASS — identity triple detects and refuses; storage attributes per kernel with a named substrate bucket'
