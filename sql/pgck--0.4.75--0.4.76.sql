-- pgck--0.4.75--0.4.76.sql — THE DOOR CAN SEE THE INFERRED PLANE.
--
-- MEASURED GAP (PASS-31, 2026-08-17), and it is this kernel's own rule broken
-- by its own author:
--
--   pgrdf_graphs (pgRDF's instrument)  -> asserted AND inferred, per graph
--   surface.grounding (this door)      -> asserted only; no inferred, anywhere
--
--   So the largest finding of the day — that the reasoner has materialized every
--   ONTOLOGY graph and has NEVER been run over any INSTANCES graph, inferred = 0
--   across eleven graphs and ~7,500 facts — is INVISIBLE THROUGH THE DOOR. It was
--   found with an instrument end users do not have, because they hold only
--   pgCK.MCP. "A check that is not a verb does not exist" — and a measurement no
--   caller can reproduce by the route available to them is the BenchOnly class
--   reached from a new direction.
--
-- FIX: surface.grounding carries `inferred` beside `asserted`, per graph.
--
-- The data was never remote: every count in this function already filters
-- `NOT q.is_inferred` against pgrdf._pgrdf_quads, so the inferred rows were in
-- the same table being read, deliberately excluded, and never reported. The
-- exclusion was correct — asserted-only counts are the blank-node-immune
-- instrument — but excluding a plane and never naming it is how a kernel ends
-- up unable to see that its own facts have never been reasoned over.
--
-- F3 COMPLIANCE: a count without its method is not a number. `inferred` names
-- its method in the planes note — entailed quads present in the graph, the
-- reasoner's output, counted whole and NOT deduplicated against asserted.
-- asserted + inferred is therefore the store's total for that graph, and
-- `inferred = 0` on a populated graph is a POSITIVE finding: nothing has ever
-- been derived from those facts.
--
-- Negative control: `inferred` must stay 0 for every /instances graph until a
-- materialization is actually run over one, and must be non-zero for the
-- ontology graphs, which are `materialized`. Both halves are observable in the
-- same call, so the field cannot be trivially satisfied.

CREATE OR REPLACE FUNCTION ckp.surface_grounding(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_iris text[];
  v_iri  text;
  v_g    bigint;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF COALESCE(btrim(p_payload->>'iri'),'') <> '' THEN
    v_iris := ARRAY[p_payload->>'iri'];
  ELSE
    v_iris := ARRAY[format('urn:ckp:%s/shapes/composed', v_proj),
                    format('urn:ckp:%s/kernel/ck', v_proj)]
              || ckp._adopted_graphs(v_proj);
  END IF;
  FOREACH v_iri IN ARRAY v_iris LOOP
    v_g := pgrdf.add_graph(v_iri);
    v_rows := v_rows || (
      SELECT jsonb_build_object(
        'iri', v_iri,
        'asserted',        count(*),
        -- 0.4.76 — the entailed plane, reported rather than filtered away. Every
        -- other count here is asserted-only BY DESIGN; this one is its complement,
        -- so a caller can see whether the reasoner has ever run over this graph
        -- without borrowing an instrument it does not have.
        'inferred',        (SELECT count(*) FROM pgrdf._pgrdf_quads qi
                             WHERE qi.graph_id = v_g AND qi.is_inferred),
        'groundTriples',   count(*) FILTER (WHERE s.term_type <> 2 AND o.term_type <> 2),
        'bnodeTriples',    count(*) FILTER (WHERE s.term_type = 2 OR o.term_type = 2),
        'distinctBnodes',  (SELECT count(DISTINCT d) FROM (
                              SELECT q2.subject_id d FROM pgrdf._pgrdf_quads q2
                                JOIN pgrdf._pgrdf_dictionary s2 ON s2.id = q2.subject_id
                               WHERE q2.graph_id = v_g AND NOT q2.is_inferred AND s2.term_type = 2
                              UNION
                              SELECT q3.object_id FROM pgrdf._pgrdf_quads q3
                                JOIN pgrdf._pgrdf_dictionary o3 ON o3.id = q3.object_id
                               WHERE q3.graph_id = v_g AND NOT q3.is_inferred AND o3.term_type = 2) u),
        'copyDigest',       ckp._surface_digest(v_g),
        'structuralDigest', ckp._structural_digest(v_g),
        'nodeshapes', (SELECT count(DISTINCT q4.subject_id) FROM pgrdf._pgrdf_quads q4
           JOIN pgrdf._pgrdf_dictionary p4 ON p4.id = q4.predicate_id
           JOIN pgrdf._pgrdf_dictionary o4 ON o4.id = q4.object_id
          WHERE q4.graph_id = v_g AND NOT q4.is_inferred
            AND p4.lexical_value = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type'
            AND o4.lexical_value = 'http://www.w3.org/ns/shacl#NodeShape'),
        'propertyShapes', (SELECT count(DISTINCT q5.subject_id) FROM pgrdf._pgrdf_quads q5
           JOIN pgrdf._pgrdf_dictionary p5 ON p5.id = q5.predicate_id
          WHERE q5.graph_id = v_g AND NOT q5.is_inferred
            AND p5.lexical_value = 'http://www.w3.org/ns/shacl#path'),
        'declaredProperties', (SELECT count(DISTINCT q6.subject_id) FROM pgrdf._pgrdf_quads q6
           JOIN pgrdf._pgrdf_dictionary p6 ON p6.id = q6.predicate_id
           JOIN pgrdf._pgrdf_dictionary o6 ON o6.id = q6.object_id
          WHERE q6.graph_id = v_g AND NOT q6.is_inferred
            AND p6.lexical_value = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type'
            AND o6.lexical_value IN ('http://www.w3.org/2002/07/owl#DatatypeProperty',
                                     'http://www.w3.org/2002/07/owl#ObjectProperty',
                                     'http://www.w3.org/2002/07/owl#AnnotationProperty',
                                     'http://www.w3.org/1999/02/22-rdf-syntax-ns#Property')))
      FROM pgrdf._pgrdf_quads q
      JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
      JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
      WHERE q.graph_id = v_g AND NOT q.is_inferred);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj, 'graphs', v_rows,
    'planes', 'FILE digests pin published bytes (verify with shasum against the sidecar). copyDigest pins THIS store''s bytes and moves on every reload — in-store drift detection only, never cross-bench identity. structuralDigest survives reload (first-degree blank-node signatures, the fleet algorithm) — what a third party recomputes from the published modules. Counts are the blank-node-immune instrument and NAME THEIR METHOD: nodeshapes (asserted sh:NodeShape typing; 42 = 27 core + 11 wave + 4 lexicon fully adopted) · declaredProperties (asserted owl/rdf property declarations; 130 = 80 + 33 + 17) · propertyShapes (asserted distinct sh:path subjects). asserted counts ASSERTED-ONLY quads; inferred (0.4.76) counts ENTAILED quads — the reasoner''s output for this graph, whole and NOT deduplicated against asserted, so asserted+inferred is the store total. A count without its method is not a number (F3).',
    'inferredNote', 'inferred = 0 on a POPULATED graph is a positive finding, not an absence of data: nothing has ever been derived from those facts. Measured 2026-08-17: every /instances graph fleet-wide read 0 while every adopted ONTOLOGY graph read non-zero, so the reasoner had run over the T-Box and never over the A-Box. lexicon#Pattern declares that membership is INFERRED from the symptom and never asserted, so a lexicon teaching cannot be earned on a graph whose inferred count is 0.',
    'verdictAsymmetry', 'unequal structural digests PROVE two graphs differ; equal ones are strong evidence of isomorphism and NOT proof (not RDFC-1.0). Never upgrade ISOMORPHIC_LIKELY to identical.');
END;
$function$;
