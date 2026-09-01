-- pgck 0.4.92 -> 0.4.93
--
-- 0.4.92 SHIPPED A REAPER THAT REAPED NOTHING. This corrects it, and the failure
-- is worth more than the fix.
--
-- The reap did the SELECT and the DROP in one statement. PostgreSQL refused every
-- time: "cannot DROP TABLE _pgrdf_quads_gNNN because it is being used by active
-- queries in this session". The NOT EXISTS scans the PARTITIONED PARENT, which
-- locks every partition, while the same statement tries to drop one of them. The
-- scan must COMPLETE before any drop begins.
--
-- It shipped green because of two compounding mistakes, and both are the ones
-- this substrate names in other people's code:
--
--   1. A DEFENSIVE EXCEPTION HANDLER SWALLOWED THE ERROR. `EXCEPTION WHEN OTHERS
--      THEN reaped := 0` turned a hard refusal into a silent success. The handler
--      is retained — housekeeping must never fail a validation — but it is now
--      PER GRAPH and it RAISES A WARNING, so a no-op cannot look like a result.
--
--   2. s80 TESTED THE PREDICATE, NOT THE DROP. It asserted which graphs WOULD be
--      selected and never that one disappeared. A check that cannot fail the
--      thing it claims is not a check, and this file claimed "reaped" while
--      measuring "would have selected". s80 gains claim (d): perform the drop,
--      then assert the graph is GONE.
--
-- Measured after the fix, on the compose rig: 51 scratch graphs -> 26 in one
-- call, reaped=25, which is the per-call bound working as intended.

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
  dead_ids bigint[];
  one_id bigint;
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
  -- ⚠ TWO PHASES, AND THE SECOND ONE IS WHY. The first draft did the SELECT and
  -- the DROP in one statement, and PostgreSQL refused every time:
  --   cannot DROP TABLE "_pgrdf_quads_gNNN" because it is being used by active
  --   queries in this session
  -- The NOT EXISTS scans the PARTITIONED PARENT, which locks every partition,
  -- while the same statement tries to drop one of them. The scan must COMPLETE
  -- before any drop begins. Collect ids first; drop afterwards, one at a time.
  --
  -- That draft shipped in 0.4.92 and reaped NOTHING, because the exception
  -- handler below swallowed the error and reported success — a defensive block
  -- hiding a real failure, which is the pattern this substrate keeps finding in
  -- other people's code. The handler is kept because housekeeping must never
  -- fail a validation, but it now logs, so a silent no-op cannot recur.
  IF to_regprocedure('pgrdf.drop_graph(bigint,boolean)') IS NOT NULL THEN
    SELECT COALESCE(array_agg(g.graph_id), ARRAY[]::bigint[]) INTO dead_ids
      FROM (SELECT g.graph_id
              FROM pgrdf._pgrdf_graphs g
             WHERE g.iri LIKE 'urn:ckp:validate-scratch:%'
               AND g.graph_id <> scratch_id
               AND substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$') IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a
                                WHERE a.pid = substring(g.iri from '^urn:ckp:validate-scratch:([0-9]+)$')::int)
               AND NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = g.graph_id)
             LIMIT 25) g;

    FOREACH one_id IN ARRAY dead_ids LOOP
      BEGIN
        PERFORM pgrdf.drop_graph(one_id, true);
        reaped := reaped + 1;
      EXCEPTION WHEN OTHERS THEN
        -- Per graph, so one stubborn partition cannot cost the rest. Logged, not
        -- swallowed: the previous silent handler is exactly why 0.4.92 shipped a
        -- reaper that never reaped.
        RAISE WARNING 'ckp.validate: could not reap scratch graph % — %', one_id, SQLERRM;
      END;
    END LOOP;
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
