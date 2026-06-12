-- ============================================================================
-- pgck 0.4.5 -> 0.4.6 — Tier 2 (3/3a): reach edge-materialization
-- ============================================================================
-- `instance.reach` (ckp.reach) runs a property-path SPARQL `<from> <via>+ ?r` over
-- the RDF graphs — so it only finds links that exist AS QUADS. But `edge.create`
-- sealed an Edge INSTANCE (a row in ckp.instances: source/predicate/target fields)
-- and never wrote a quad, so a participant who linked two instances then called
-- reach got `[]` — the edge was recorded but not traversable. (s30 only passed
-- because it pre-seeded quads with parse_turtle directly.)
--
-- ckp.materialize_edge writes the traversable quad `<source> <predicate> <target>`
-- into a per-project edge graph (urn:ckp:<project>/edges) when edge.create seals,
-- so reach now traverses real participant-created links. Injection-safe: source,
-- predicate, and target are IRI-gated before the Turtle is built (the only values
-- interpolated), and a non-IRI endpoint seals the Edge instance WITHOUT a quad
-- (the link is recorded but flagged not-traversable — never a silent failure).
--
-- The governed concept.match form (author a QueryAffordance -> seal via governance ->
-- compile -> bind) is a separate, larger feature tracked on its own; this file lands
-- the reach half of Tier 2 (3/3).
--
-- Exit test: sql/test/s40_reach_edge_materialization.sql — edge.create A->B, B->C
-- through the dispatch door (as ck_participant), then reach(from=A, via=pred) returns
-- {B, C} transitively. Participant-created edges are now traversable.
-- ============================================================================

CREATE OR REPLACE FUNCTION ckp.materialize_edge(p_src text, p_pred text, p_tgt text, p_project text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $me$
DECLARE
  v_iri_re text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';   -- no quote/space/newline/'>' can reach the TTL
  v_pred   text := CASE WHEN position(':' in COALESCE(p_pred,'')) > 0
                        THEN p_pred                                     -- already an IRI: as-is
                        ELSE 'https://conceptkernel.org/ontology/v3.7/' || p_pred END;  -- short -> v3.7 IRI
  v_g      bigint;
BEGIN
  -- Only materialize when source/target are absolute IRIs and all three are clean.
  -- A bare id (e.g. 'task-123', no scheme) seals the Edge instance but gets no quad;
  -- callers link instance @ids (ckp://Type#id), which ARE IRIs.
  IF p_src IS NULL OR p_tgt IS NULL
     OR position(':' in p_src) = 0 OR position(':' in p_tgt) = 0
     OR p_src !~ v_iri_re OR v_pred !~ v_iri_re OR p_tgt !~ v_iri_re THEN
    RETURN false;
  END IF;
  v_g := pgrdf.add_graph(format('urn:ckp:%s/edges', p_project));   -- per-project edge graph (get-or-create)
  PERFORM pgrdf.parse_turtle(format('<%s> <%s> <%s> .', p_src, v_pred, p_tgt),
                             v_g, format('urn:ckp:%s/edges#', p_project));
  RETURN true;
END;
$me$;
ALTER FUNCTION ckp.materialize_edge(text, text, text, text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.materialize_edge(text, text, text, text) IS
  'Tier 2 (3/3a): on edge.create, write the traversable quad <src> <pred> <tgt> into '
  'urn:ckp:<project>/edges so instance.reach traverses participant-created links. IRI-gated '
  '(injection-safe); a non-IRI endpoint seals the Edge instance without a quad (reachable:false).';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
