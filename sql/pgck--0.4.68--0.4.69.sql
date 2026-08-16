-- pgck 0.4.68 → 0.4.69 — DIGESTS AT THE DOOR, NEVER IN THE LOOP
--
-- ckp.seal composes the surface it judges against, so _composed_shapes runs on
-- EVERY seal — and 0.4.67's pin insert computed the structural digest, the
-- copy digest and two counts of EVERY adopted module per seal, then discarded
-- them: ON CONFLICT DO NOTHING evaluates the VALUES expressions first.
-- Measured on the rig: the recompose paid tens of milliseconds per seal for
-- work whose answer never changes after first composition.
--
-- The fleet's boundary rule — "digests at the door, hash-chains in the loop,
-- seals on the boundary; a fingerprint inside a hot step is the smell, because
-- 'same graph?' is an admission question and admission happens once" — caught
-- this in pgck's own day-old code, its second prevented-or-caught defect in
-- two days. The pin is trust-on-FIRST-sight by definition: the digest work now
-- runs only when the pin is absent; every later composition copies and moves on.
--
-- Changed: _composed_shapes.
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
    --
    -- 0.4.69 — DIGESTS AT THE DOOR, NEVER IN THE LOOP. This runs on EVERY seal
    -- (ckp.seal composes the surface it judges against), and ON CONFLICT DO
    -- NOTHING evaluates the VALUES first — so 0.4.67 silently computed both
    -- digests and two counts of every adopted module per seal and threw them
    -- away. The fleet's boundary rule ("if anyone proposes a fingerprint
    -- inside a hot step, that's the smell — admission happens once") caught
    -- its second defect in two days, this one in pgck's own day-old code. The
    -- pin is trust-on-FIRST-sight by definition: compute only when absent.
    IF EXISTS (SELECT 1 FROM ckp.adoption_pins ap WHERE ap.graph_iri = v_iri) THEN
      PERFORM pgrdf.copy_graph(v_mod, v_comp);
      CONTINUE;
    END IF;
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

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
