-- pgck 0.4.93 -> 0.4.94
--
-- D-1 — A STORED DIGEST MUST CARRY ITS METHOD.
--
-- Raised by pgRDF, reproduced here on two doors before accepting it.
-- ckp.adoption_pins has a column named `graph_digest` populated with
-- ckp._surface_digest() — the COPY plane: sha256 over rendered lines WITH
-- blank-node labels, so it moves on every reload and no third party can
-- recompute it. Since pgRDF v0.6.32 the name `graph_digest` means RDFC-1.0,
-- where equal IS proof. The column and the engine now disagree by NAME.
--
-- Measured, and this is what makes it conclusive rather than suspicious: on
-- every pinned graph the fd1 (structural) digests MATCH and the counts MATCH,
-- so the modules did NOT drift. The stored value nonetheless disagrees with the
-- engine, and differs BETWEEN DOORS for byte-identical content (lexicon pins as
-- 4a84daf6… on ckdev and 1f73c722… on pgck, while the engine says 7622d623…
-- on both). A reader diffing pins across doors concludes the adopted module
-- changed, and is wrong every time.
--
-- Two columns, not four. `methods` names the plane of every stored digest in one
-- place; `canonical_digest` adds the plane two parties can actually compare.
-- Existing readers are untouched, and bench-local drift detection — a real job —
-- keeps working; it simply stops claiming to be something it never was.
--
-- The backfill deliberately does NOT invent a canonical digest for existing
-- pins. We never measured what RDFC would have said at pin time, and computing
-- it from the graph now would assert a historical fact. Absence is an answer.
--
-- Proof: sql/test/tdd/tdd01_obligations.sql, obligation D-1, flipped RED->GREEN.
-- Its control is the load-bearing half — it requires at least one pin where the
-- copy plane DISAGREES with the engine while fd1 AGREES, because if the planes
-- ever coincided the method label would be decoration. Three false GREENs were
-- caught and fixed while writing it: an empty graph where both planes returned
-- sha256(""), a fixture skipped by ON CONFLICT, and a canonical check that
-- passed vacuously when no canonical pin existed.

DO $$ BEGIN
  -- 0.4.94 (D-1) — A STORED DIGEST MUST CARRY ITS METHOD.
  -- `graph_digest` is populated with ckp._surface_digest(), the COPY plane:
  -- sha256 over rendered lines WITH blank-node labels, so it moves on every
  -- reload and no third party can recompute it. The column name now collides
  -- with pgrdf.graph_digest(), which since v0.6.32 means RDFC-1.0 — where equal
  -- IS proof. Measured on two doors: fd1 MATCHES and counts MATCH on every
  -- pinned graph, so the modules did not drift, while the stored value disagrees
  -- with the engine AND differs between doors for identical content. A reader
  -- diffing pins across doors concludes the module changed, and is wrong every
  -- time. Raised by pgRDF; reproduced here before accepting it.
  --
  -- Two columns, not four: `methods` names every plane in one place, and
  -- `canonical_digest` adds the plane that is actually comparable between
  -- parties. Existing readers are untouched.
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS methods JSONB;
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS canonical_digest TEXT;

  -- Backfill the METHODS of what is already stored — and deliberately NOT the
  -- canonical digest. We do not know what RDFC would have said at pin time, and
  -- computing it from the graph NOW would assert a historical fact we never
  -- measured. Absence is an answer; an invented pin is not.
  UPDATE ckp.adoption_pins SET methods = jsonb_build_object(
      'graph_digest',     'ckp-copy-sha256',
      'structural_digest','pgrdf-fd1-sha256',
      'canonical_digest', NULL)
   WHERE methods IS NULL;


END $$;

CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text, p_exclude text DEFAULT NULL)
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
  -- 0.4.79 -- CORE-ONLY IS A REAL STATE. Composition is the act of unioning a
  -- kernel's own graph and its sealed Adoptions INTO core. With no kernel there
  -- is nothing to union, so the surface simply IS core -- returned directly
  -- rather than copied into an invented urn:ckp:<somebody>/shapes/composed.
  -- Reads and validation work here; sealing refuses in _derived_stamps.
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RETURN v_core;
  END IF;
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
    -- 0.4.73 — THE CURE IS EXEMPT FROM THE POISON IT REMOVES. p_exclude names
    -- the ONE graph a core#Supersession being sealed right now is about to
    -- un-adopt (derived by ckp.seal from the candidate itself, never caller-
    -- supplied). Without this, a dangling adoption DEADLOCKS its project: every
    -- seal composes, composition raises on the dangling graph, and the raise's
    -- own remedy — "seal a Supersession" — is itself a seal. Measured live:
    -- ontosys, poisoned within hours of germinating, could not reach its cure;
    -- s68's victim project proves both halves. The exclusion is content-honest:
    -- skipping a graph the Supersession removes narrows nothing the resulting
    -- surface should still carry — and for the dangling case the graph is
    -- empty anyway. Fail-closed stands for every other seal.
    CONTINUE WHEN p_exclude IS NOT NULL AND v_iri = p_exclude;
    v_mod := pgrdf.add_graph(v_iri);
    SELECT count(*) INTO v_cnt
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } } LIMIT 1', v_iri));
    IF v_cnt = 0 THEN
      RAISE EXCEPTION 'ckp._composed_shapes: adopted module graph % is absent or empty — a sealed Adoption names it, so composing without it would silently narrow the enforcement surface. Load the module graph or seal a Supersession (the Supersession seal itself is exempt from this check for the graph it removes).', v_iri;
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
    -- 0.4.94 (D-1): every plane stored WITH its method, plus the canonical
    -- plane, which is the only one two parties can compare. The copy plane is
    -- retained because bench-local drift detection is a real job — it is simply
    -- not the job its column name implied.
    INSERT INTO ckp.adoption_pins(graph_iri, graph_digest, structural_digest,
                                  canonical_digest, methods, nodeshapes, properties, asserted)
    VALUES (v_iri, ckp._surface_digest(v_mod), ckp._structural_digest(v_mod),
      CASE WHEN to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL
           THEN pgrdf.graph_digest(v_mod) ELSE NULL END,
      jsonb_build_object(
        'graph_digest',     'ckp-copy-sha256',
        'structural_digest','pgrdf-fd1-sha256',
        'canonical_digest', CASE WHEN to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL
                                 THEN 'rdfc-1.0-sha256' ELSE NULL END),
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
