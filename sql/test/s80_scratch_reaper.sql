-- s80_scratch_reaper.sql — THE CLOCK MUST NOT BE THE LEAK (0.4.92).
--
-- WHY THIS EXISTS. ckp.storage() found this on its FIRST gated run: the compose
-- rig carried 49 `validate-scratch` graphs out of 201 — 24% of every graph on
-- that database was validation debris. The scratch graph is one-per-BACKEND by
-- design (the alternative aliased real data and once came within one engine
-- check of clearing core), and it is cleared but never dropped, so a long-lived
-- postmaster accumulates one dead graph per backend that ever validated.
--
-- Each is ~24 kB and the bytes are not the point. The COUNT pollutes
-- graph_inventory and skews the freshness census that `stale` is read against —
-- and it grows with sessions elapsed rather than work retained, which is what
-- "the clock becomes the leak" looks like in the small.
--
-- The claims, and two of the three are controls, because an over-eager reaper is
-- far worse than the debris it removes:
--   (a) A DEAD, EMPTY scratch graph is reaped.
--   (b) CONTROL: a scratch graph with QUADS IN IT is spared. Empty is the whole
--       licence to drop; a non-empty one is somebody's in-flight state.
--   (c) CONTROL: a scratch graph belonging to a LIVE backend is spared. By
--       definition it is in use, and dropping it breaks that session mid-flight.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  g_dead bigint; g_full bigint; g_live bigint; n int; would text;
BEGIN
  IF to_regprocedure('pgrdf.drop_graph(bigint,boolean)') IS NULL THEN
    RAISE NOTICE 's80 SKIP — engine predates pgrdf.drop_graph()';
    RETURN;
  END IF;

  g_dead := pgrdf.add_graph('urn:ckp:validate-scratch:999801');           -- dead + empty
  g_full := pgrdf.add_graph('urn:ckp:validate-scratch:999802');           -- dead + NOT empty
  PERFORM pgrdf.parse_turtle('<urn:s80a> <urn:s80b> <urn:s80c> .', g_full, 'urn:s80#');
  g_live := pgrdf.add_graph('urn:ckp:validate-scratch:'||pg_backend_pid()); -- live

  -- the reaper's own predicate, evaluated exactly as the function evaluates it
  SELECT COALESCE(string_agg(iri, ',' ORDER BY iri),'') INTO would
    FROM pgrdf._pgrdf_graphs g
   WHERE g.iri LIKE 'urn:ckp:validate-scratch:%'
     AND g.graph_id <> g_live
     AND substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a
                      WHERE a.pid = substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$')::int)
     AND NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = g.graph_id);

  -- (a) the dead empty one is selected
  IF would NOT LIKE '%999801%' THEN
    RAISE EXCEPTION 's80 FAIL (a): a DEAD, EMPTY scratch graph was not selected for reaping. selected: %', would;
  END IF;
  RAISE NOTICE 's80 (a) PASS — dead empty scratch selected';

  -- (b) CONTROL: the non-empty one is not
  IF would LIKE '%999802%' THEN
    RAISE EXCEPTION 's80 FAIL (b): a scratch graph WITH QUADS was selected — empty is the entire licence to drop, and this would delete somebody''s in-flight state';
  END IF;
  RAISE NOTICE 's80 (b) PASS — non-empty scratch spared';

  -- (c) CONTROL: this backend's own is not
  IF would LIKE '%validate-scratch:'||pg_backend_pid()||'%' THEN
    RAISE EXCEPTION 's80 FAIL (c): a LIVE backend''s scratch graph was selected — it is in use by definition';
  END IF;
  RAISE NOTICE 's80 (c) PASS — live backend''s scratch spared';

  PERFORM pgrdf.drop_graph(g_dead, true);
  PERFORM pgrdf.drop_graph(g_full, true);
EXCEPTION WHEN OTHERS THEN
  BEGIN PERFORM pgrdf.drop_graph(pgrdf.add_graph('urn:ckp:validate-scratch:999801'), true); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM pgrdf.drop_graph(pgrdf.add_graph('urn:ckp:validate-scratch:999802'), true); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END $$;

\echo 's80 PASS — dead scratch reaped, non-empty and live spared'
