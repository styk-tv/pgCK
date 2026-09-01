-- pgck 0.4.91 -> 0.4.92
--
-- THE CLOCK MUST NOT BE THE LEAK.
--
-- ckp.storage() shipped in 0.4.91 and found this on its FIRST gated run: the
-- compose rig carried 49 validate-scratch graphs out of 201 — 24% of every graph
-- on that database was validation debris. That is the argument for building the
-- instrument, made by the instrument.
--
-- The scratch graph is one-per-BACKEND by design (the arithmetic alternative once
-- aimed clear_graph at real data and only pgrdf's IRI-binding check stood between
-- that and deleting core), and it is CLEARED but never DROPPED. So a long-lived
-- postmaster accumulates one dead graph per backend that ever validated. Each is
-- ~24 kB and the bytes are not the point: the COUNT pollutes graph_inventory and
-- skews the freshness census `stale` is read against, and it grows with sessions
-- elapsed rather than work retained.
--
-- Reaped at the point of use rather than on the bgworker tick. The tick is a
-- pulse, not a scheduler; giving it per-kernel cleanup couples every kernel's
-- latency to every other kernel's debris. Reaping here is self-limiting in the
-- right direction — the more validation runs, the more reaping happens,
-- proportional to the activity that creates the mess — and bounded per call so
-- no single validate pays an unbounded cost.
--
-- Three conditions, ALL required, and two of them are the safety: named
-- validate-scratch, EMPTY, and its pid is not an active backend. An over-eager
-- reaper is far worse than the debris; a non-empty scratch is somebody's
-- in-flight state and a live backend's is in use by definition.
--
-- Honest limit, found by testing rather than assumed: the reap shares the
-- function's transaction, so a validate that REFUSES rolls the drops back.
-- Reaping happens on successful validations only — the correct trade, since
-- housekeeping must never be why a refusal fails to refuse.
--
-- Negative control: sql/test/s80_scratch_reaper.sql — one claim and two controls.

CREATE OR REPLACE FUNCTION ckp.validate(ttl text, shapes_graph_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- The scratch graph is allocated BY IRI, never computed as
  -- 1000000000 + pg_backend_pid(). That arithmetic lands inside the very band
  -- pgrdf allocates data graphs from: on the bench 59 live graphs sat at
  -- offsets 112..1637 -- ordinary container pids -- with the core ontology
  -- itself at 1000000221. A backend that drew a colliding pid aimed
  -- clear_graph at real data, and every seal in that session refused with a
  -- shape error that had nothing to do with the payload. Only pgrdf's
  -- "bound to a different IRI" check stood between this and deleting core.
  -- add_graph(iri) is idempotent and returns the id, so the scratch stays
  -- one-per-backend and can never alias a data graph.
  scratch_id BIGINT := pgrdf.add_graph('urn:ckp:validate-scratch:'||pg_backend_pid());
  report jsonb;
  reaped int := 0;
BEGIN
  -- 0.4.92 — REAP THE DEAD SCRATCH GRAPHS. Found by ckp.storage() on its FIRST
  -- gated run, which is the whole argument for building the instrument: the
  -- compose rig reported 49 validate-scratch graphs out of 201 — 24% of every
  -- graph on that database was validation debris. Each is only ~24 kB, and the
  -- bytes are not the point: the count pollutes graph_inventory, skews the
  -- freshness census `stale` is read against, and grows without bound for the
  -- life of the instance.
  --
  -- The scratch graph is one-per-BACKEND by design (see the note above — the
  -- alternative aliased real data), and it is cleared but never dropped. So a
  -- long-lived postmaster accumulates one dead graph per backend that ever
  -- validated. This is what "the clock becomes the leak" looks like in the
  -- small: growth tracking sessions elapsed rather than work retained.
  --
  -- ONE HONEST LIMIT, found by testing: the reap shares this function's
  -- transaction, so a validate that REFUSES (the vacuity guard, a parse error)
  -- rolls the drops back with everything else. Reaping therefore happens on
  -- successful validations only. That is the correct trade — housekeeping must
  -- never be the reason a refusal fails to refuse — and it is stated here rather
  -- than discovered later as a mystery about why debris survives a busy day.
  --
  -- Reaped HERE rather than on the bgworker tick, and that is deliberate. The
  -- tick is a pulse, not a scheduler; giving it per-kernel cleanup work couples
  -- every kernel's latency to every other kernel's debris. Reaping at the point
  -- of use is self-limiting in exactly the right direction: the more validation
  -- runs, the more reaping happens, proportional to the activity that creates
  -- the mess. Bounded per call so no single validate pays an unbounded cost.
  --
  -- Three conditions, all required, because a scratch graph belonging to a LIVE
  -- backend is in use by definition and dropping it would break that session:
  --   named validate-scratch  ·  EMPTY  ·  its pid is not an active backend.
  IF to_regprocedure('pgrdf.drop_graph(bigint,boolean)') IS NOT NULL THEN
    BEGIN
      WITH dead AS (
        SELECT g.graph_id, g.iri
          FROM pgrdf._pgrdf_graphs g
         WHERE g.iri LIKE 'urn:ckp:validate-scratch:%'
           AND g.graph_id <> scratch_id
           AND substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a
                            WHERE a.pid = substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$')::int)
           AND NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = g.graph_id)
         LIMIT 25)
      SELECT count(*) INTO reaped FROM (
        SELECT pgrdf.drop_graph(d.graph_id, true) FROM dead d) x;
    EXCEPTION WHEN OTHERS THEN
      -- Reaping is HOUSEKEEPING and must never fail a validation. If the engine
      -- refuses a drop, the debris stays and ckp.storage() keeps reporting it —
      -- visible, which is the honest failure mode.
      reaped := 0;
    END;
  END IF;
  -- Bench-proven form (reconciled from pgck.localhost, 2026-08-08): the graph
  -- is materialized BEFORE validation. pgrdf.validate does not entail and
  -- entailment is per-graph, so without this the candidate's rdf:type closure
  -- is invisible to targetClass resolution and a malformed entry can conform
  -- vacuously — the PASS-10/PASS-17 failure shape, at the innermost gate.
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  PERFORM pgrdf.materialize(scratch_id);
  report := pgrdf.validate(scratch_id, shapes_graph_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$function$
;
