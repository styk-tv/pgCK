-- pgck 0.4.67 → 0.4.68 — COUNTS NAME THEIR METHOD
--
-- F3, reproduced in pgck's own brand-new census the hour it shipped: 0.4.67's
-- surface.grounding reported "properties" counted as sh:path rows THROUGH
-- SPARQL — which reads the inferred closure — while the fleet's arithmetic
-- (80+33+17=130) counts asserted declared vocabulary properties, and a third
-- honest method (asserted distinct property-shape subjects) gives 107/44/10.
-- Three methods, three numbers, one unnamed label. Measured on the founding
-- graphs before anyone was misled.
--
-- Now every count is ASSERTED-ONLY, distinct, and names its method:
--   nodeshapes          asserted sh:NodeShape typing        27 / 11 / 4
--   declaredProperties  asserted owl/rdf property decls     80 / 33 / 17
--   propertyShapes      asserted distinct sh:path subjects  107 / 44 / 10
-- adoption_pins' counts use the same two named instruments. s65 gains the
-- arithmetic acceptance (27 / 80 on the core graph, through the door).
--
-- Changed: _composed_shapes, surface_grounding.
CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text DEFAULT 'demo'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_core int; v_kernel int; v_comp int; v_mod int;
  v_iri  text;
  v_cnt  int;
BEGIN
  v_core   := pgrdf.add_graph('urn:ckp:core');
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  v_comp   := pgrdf.add_graph(format('urn:ckp:%s/shapes/composed', p_project));
  PERFORM pgrdf.clear_graph(v_comp);
  PERFORM pgrdf.copy_graph(v_core,   v_comp);
  PERFORM pgrdf.copy_graph(v_kernel, v_comp);
  -- A2: every graph a sealed unsuperseded Adoption names joins the surface.
  -- Module-IRI-is-graph-IRI: the adopts value IS the graph. Fail CLOSED on a
  -- dangling or empty reference — a vanished module silently narrowing the
  -- gate is un-enforcement nobody would see.
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(p_project) LOOP
    v_mod := pgrdf.add_graph(v_iri);
    SELECT count(*) INTO v_cnt
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } } LIMIT 1', v_iri));
    IF v_cnt = 0 THEN
      RAISE EXCEPTION 'ckp._composed_shapes: adopted module graph % is absent or empty — a sealed Adoption names it, so composing without it would silently narrow the enforcement surface. Load the module graph or seal a Supersession.', v_iri;
    END IF;
    -- 0.4.61: pin the graph's canonical digest at FIRST composition. Verification
    -- happens in adoption.check / the oracle, never here — B4's rule: a report
    -- may be wrong cheaply, a gate may not, and a false drift-positive in the
    -- hot path would refuse every seal for the project. Detection, declared.
    -- 0.4.67: the pin carries BOTH planes plus the structural counts. The copy
    -- digest detects in-store drift; the structural digest is what a party on
    -- ANOTHER store verifies against (three loads of one module share it); the
    -- counts (NodeShapes/properties/asserted) are the blank-node-immune third
    -- instrument — the 27+11+4=42 arithmetic, per module.
    -- 0.4.68: pin counts are ASSERTED-ONLY, distinct, and use the two named
    -- methods (F3): nodeshapes = asserted sh:NodeShape typing (11 wave, 4
    -- lexicon); properties = declared vocabulary properties (33, 17) — the
    -- fleet's 27+11+4 / 80+33+17 arithmetic, per module. The first cut read
    -- sh:path rows through SPARQL, which counts the inferred closure too.
    INSERT INTO ckp.adoption_pins(graph_iri, graph_digest, structural_digest, nodeshapes, properties, asserted)
    VALUES (v_iri, ckp._surface_digest(v_mod), ckp._structural_digest(v_mod),
      (SELECT count(DISTINCT q4.subject_id) FROM pgrdf._pgrdf_quads q4
         JOIN pgrdf._pgrdf_dictionary p4 ON p4.id = q4.predicate_id
         JOIN pgrdf._pgrdf_dictionary o4 ON o4.id = q4.object_id
        WHERE q4.graph_id = v_mod AND NOT q4.is_inferred
          AND p4.lexical_value = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type'
          AND o4.lexical_value = 'http://www.w3.org/ns/shacl#NodeShape'),
      (SELECT count(DISTINCT q6.subject_id) FROM pgrdf._pgrdf_quads q6
         JOIN pgrdf._pgrdf_dictionary p6 ON p6.id = q6.predicate_id
         JOIN pgrdf._pgrdf_dictionary o6 ON o6.id = q6.object_id
        WHERE q6.graph_id = v_mod AND NOT q6.is_inferred
          AND p6.lexical_value = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type'
          AND o6.lexical_value IN ('http://www.w3.org/2002/07/owl#DatatypeProperty',
                                   'http://www.w3.org/2002/07/owl#ObjectProperty',
                                   'http://www.w3.org/2002/07/owl#AnnotationProperty',
                                   'http://www.w3.org/1999/02/22-rdf-syntax-ns#Property')),
      (SELECT count(*) FROM pgrdf._pgrdf_quads q WHERE q.graph_id = v_mod AND NOT q.is_inferred))
    ON CONFLICT (graph_iri) DO NOTHING;
    PERFORM pgrdf.copy_graph(v_mod, v_comp);
  END LOOP;
  -- Entailment is per-graph and pgrdf.validate does not entail, so the closure
  -- is computed HERE, once, rather than depended on at validate time.
  PERFORM pgrdf.materialize(v_comp);
  RETURN v_comp;
END;
$function$
;

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
  -- an explicit {iri} examines ONE graph (the brought-graph admission read);
  -- with no payload the kernel's whole ground is censused.
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
        -- 0.4.68 — COUNTS NAME THEIR METHOD (F3: two shape counts disagreed in
        -- the same instant because neither named its method; this verb shipped
        -- a third). Measured on the founding graphs, three methods, three
        -- numbers: declared vocabulary properties 80/33/17 (the fleet's
        -- arithmetic), asserted property shapes 107/44/10, sh:path rows with
        -- inferred = a fourth. All counts here are ASSERTED-ONLY and distinct.
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
    'planes', 'FILE digests pin published bytes (verify with shasum against the sidecar). copyDigest pins THIS store''s bytes and moves on every reload — in-store drift detection only, never cross-bench identity. structuralDigest survives reload (first-degree blank-node signatures, the fleet algorithm) — what a third party recomputes from the published modules. Counts are the blank-node-immune instrument and NAME THEIR METHOD: nodeshapes (asserted sh:NodeShape typing; 42 = 27 core + 11 wave + 4 lexicon fully adopted) · declaredProperties (asserted owl/rdf property declarations; 130 = 80 + 33 + 17) · propertyShapes (asserted distinct sh:path subjects). A count without its method is not a number (F3).',
    'verdictAsymmetry', 'unequal structural digests PROVE two graphs differ; equal ones are strong evidence of isomorphism and NOT proof (not RDFC-1.0). Never upgrade ISOMORPHIC_LIKELY to identical.');
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
