-- s79_engine_surface_adopted.sql — WE CALL THE ENGINE RATHER THAN RE-IMPLEMENT IT (0.4.91).
--
-- WHY THIS EXISTS. pgRDF v0.6.34 shipped instruments this substrate had been
-- doing without, or duplicating. Their LIB spec's closing line is the brief:
-- "the law arrives pre-typed — the screen's honesty is a rendering job, not a
-- reconstruction job. That was the whole point of the E-series: build on it."
--
-- Three ways to get this wrong, and one gate each:
--   1. Delegate to a function that does NOT agree, silently changing what every
--      structural pin in the ledger means.
--   2. Conflate the two digest planes, so an ISOMORPHIC_LIKELY reads as proof.
--   3. Claim a completeness we did not measure — the session-local trap: report
--      some other query's stats as if they were this read's.
--
-- The claims:
--   (a) DELEGATION AGREES. ckp._structural_digest and pgrdf.structural_digest
--       return the same value wherever both exist. This is the check that makes
--       the delegation falsifiable rather than an act of faith.
--   (b) CONTROL FOR (a): the two PLANES differ. If fd1 and RDFC ever returned the
--       same value, (a) would pass while we had quietly wired one to the other.
--   (c) NO BARE NUMBERS. Every digest carries its method; a value without one is
--       not a pin.
--   (d) STORAGE IS A STATE. `never` and `unknown` are counted, not alarmed; only
--       `stale` and non-zero orphans are warnings.
--   (e) COMPLETENESS IS MEASURED OR DECLARED ABSENT — never assumed. The verdict
--       is one of complete | short | unreported, and `unreported` is a state.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  g bigint; d jsonb; st jsonb; ec jsonb; n int;
BEGIN
  SELECT graph_id INTO g FROM pgrdf._pgrdf_graphs ORDER BY graph_id LIMIT 1;
  IF g IS NULL THEN RAISE EXCEPTION 's79: no graph to measure — fixture problem, not a result'; END IF;

  -- (a) the delegation agrees ------------------------------------------------
  IF to_regprocedure('pgrdf.structural_digest(bigint)') IS NOT NULL THEN
    IF ckp._structural_digest(g) IS DISTINCT FROM pgrdf.structural_digest(g) THEN
      RAISE EXCEPTION 's79 FAIL (a): ckp._structural_digest and pgrdf.structural_digest DISAGREE on graph % — every structural pin in this ledger would silently mean something the engine does not agree with. ckp=% pgrdf=%',
        g, ckp._structural_digest(g), pgrdf.structural_digest(g);
    END IF;
    RAISE NOTICE 's79 (a) PASS — delegation agrees with the engine on graph %', g;
  ELSE
    RAISE NOTICE 's79 (a) SKIP — engine predates pgrdf.structural_digest(); the local body is in force';
  END IF;

  d := ckp.digests(g);

  -- (b) THE CONTROL: the two planes are genuinely different computations -----
  IF d->'canonical'->>'value' IS NOT NULL THEN
    IF d->'structural'->>'value' = d->'canonical'->>'value' THEN
      RAISE EXCEPTION 's79 FAIL (b): fd1 and RDFC-1.0 returned the SAME value — the planes have been conflated, and (a) would pass while proving nothing';
    END IF;
    IF d->'canonical'->>'equalMeans' NOT LIKE 'PROOF%' THEN
      RAISE EXCEPTION 's79 FAIL (b): the canonical plane does not declare that equality is proof';
    END IF;
    RAISE NOTICE 's79 (b) PASS — the two planes are distinct computations, each declaring what equality means';
  ELSE
    RAISE NOTICE 's79 (b) SKIP — engine predates pgrdf.graph_digest(); canonical plane correctly reported unavailable';
  END IF;

  -- (c) no digest without its method -----------------------------------------
  IF d->'structural'->>'method' IS DISTINCT FROM 'pgrdf-fd1-sha256' THEN
    RAISE EXCEPTION 's79 FAIL (c): the structural plane does not carry its method label — a digest whose method is not stated is not a pin';
  END IF;
  IF d->'canonical'->>'value' IS NOT NULL
     AND d->'canonical'->>'method' IS DISTINCT FROM 'rdfc-1.0-sha256' THEN
    RAISE EXCEPTION 's79 FAIL (c): the canonical plane carries a value without its method';
  END IF;
  RAISE NOTICE 's79 (c) PASS — every value carries its method';

  -- (d) storage reports states, not alarms -----------------------------------
  st := ckp.storage();
  IF (st->>'available')::boolean THEN
    IF NOT (st ? 'materialization') OR NOT (st ? 'orphanPartitions') THEN
      RAISE EXCEPTION 's79 FAIL (d): storage is available but does not report materialization/orphans';
    END IF;
    IF (st->>'bytes')::bigint <= 0 THEN
      RAISE EXCEPTION 's79 FAIL (d): storage reported a non-positive size';
    END IF;
    RAISE NOTICE 's79 (d) PASS — storage: % across % graphs, orphans=%, scratch=%',
      st->>'pretty', st->>'graphs', st->>'orphanPartitions', st->>'scratchGraphs';
  ELSE
    IF st->>'note' NOT LIKE '%state, not a fault%' THEN
      RAISE EXCEPTION 's79 FAIL (d): storage unavailable and did not say that absence is a STATE';
    END IF;
    RAISE NOTICE 's79 (d) PASS — storage unavailable, reported as a state';
  END IF;

  -- (e) completeness measured, or declared absent — never assumed ------------
  ec := ckp._engine_completeness();
  IF ec->'engine'->>'verdict' NOT IN ('complete','short','unreported') THEN
    RAISE EXCEPTION 's79 FAIL (e): engine verdict % is outside the closed set', ec->'engine'->>'verdict';
  END IF;
  IF ec->'engine'->>'verdict' = 'unreported'
     AND ec->'engine'->>'note' NOT LIKE '%not a claim of completeness%' THEN
    RAISE EXCEPTION 's79 FAIL (e): an UNREPORTED verdict must say it is not a claim of completeness — silence that reads as success is the defect';
  END IF;
  IF ec->'engine'->>'verdict' <> 'unreported' AND NOT (ec->'engine' ? 'pathDepthTruncations') THEN
    RAISE EXCEPTION 's79 FAIL (e): a measured verdict without the numbers behind it is an assertion';
  END IF;
  RAISE NOTICE 's79 (e) PASS — engine completeness is % and carries its method', ec->'engine'->>'verdict';
END $$;

\echo 's79 PASS — engine surface adopted, delegation falsifiable, planes distinct, completeness measured'
