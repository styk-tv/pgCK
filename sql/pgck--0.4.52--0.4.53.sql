-- pgck 0.4.53 — the vacuity detector was itself vacuous.
--
-- 0.4.52 shipped surface.unshaped as one SPARQL query using
--     FILTER NOT EXISTS { ?sh sh:targetClass ?c }
-- pgrdf SILENTLY DROPS IT. Measured within minutes: the verb returned 55 rows
-- including core#Kernel and wave#Finding, while surface.typecheck reported
-- shaped:true for both — two answers from one surface, and the wrong one was the
-- checker. Same family as the FILTER(?g IN …) drop that 0.4.51's _type_admitted
-- exists to fix, and it means THIS PASS BUILT THE DEFECT IT WAS WRITTEN TO
-- DETECT, inside the tool meant to detect it.
--
-- Fixed by taking the difference in SQL over two plain queries — no FILTER
-- anywhere. The failure direction now matters and is correct: if the engine ever
-- drops one of these, the answer is EMPTY, not EVERYTHING.
--
-- Recorded rather than quietly corrected: "the negative control caught it" is
-- only worth something if the near-miss is on the record too.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

CREATE OR REPLACE FUNCTION ckp.surface_unshaped(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_comp int; v_ci text; v_rows jsonb;
BEGIN
  v_comp := ckp._composed_shapes(v_proj);
  v_ci   := pgrdf.graph_iri(v_comp);
  -- 0.4.52 — THE ANTI-JOIN IS DONE HERE, NOT IN A FILTER THE ENGINE IGNORES.
  --
  -- The obvious form is one query with FILTER NOT EXISTS { ?sh sh:targetClass ?c }.
  -- It is SILENTLY DROPPED — same family as the FILTER(?g IN …) defect this
  -- version's _type_admitted exists to fix. Measured within minutes of shipping
  -- it: surface.vacuity returned 55 rows including core#Kernel and wave#Finding,
  -- while surface.typecheck reported shaped:true for both. Two answers from one
  -- surface, and the one that was WRONG was the checker.
  --
  -- So this pass built the exact defect it was written to detect, in the tool
  -- meant to detect it — a check that cannot fail the thing it claims. It is
  -- recorded rather than quietly corrected because "the negative control caught
  -- it" is only worth something if the near-miss is also on the record.
  --
  -- Two plain queries, difference taken in SQL. No FILTER anywhere. If the engine
  -- ever drops one of THESE, the result is empty rather than everything — the
  -- failure direction matters, and this one fails closed.
  SELECT COALESCE(jsonb_agg(c ORDER BY c), '[]'::jsonb) INTO v_rows FROM (
    SELECT j->>'c' AS c FROM pgrdf.sparql(format($q$
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      PREFIX owl:  <http://www.w3.org/2002/07/owl#>
      SELECT DISTINCT ?c WHERE { GRAPH <%1$s> { { ?c a rdfs:Class } UNION { ?c a owl:Class } } }
    $q$, v_ci)) j
    EXCEPT
    SELECT k->>'c' FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT DISTINCT ?c WHERE { GRAPH <%1$s> { ?sh sh:targetClass ?c } }
    $q$, v_ci)) k
  ) d;
  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj, 'surface', v_ci,
    'epoch', COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0),
    'surfaceDigest', ckp._surface_digest(v_comp),
    'unshaped', v_rows,
    'count', jsonb_array_length(v_rows),
    'note', 'a class this surface DECLARES that no shape TARGETS. An instance of one seals with conformsToShape absent — admitted, ledgered, and judged by nothing. owl:Thing/owl:Nothing are structural and expected.');
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
