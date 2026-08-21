-- pgck--0.4.78--0.4.79.sql — THE SUBSTRATE STOPS INVENTING A KERNEL,
-- AND STARTS TELLING THE TRUTH ABOUT NOT HAVING ONE.
--
-- COUNTED 2026-08-21 (finding-1787292096161920000): 'demo' entered on the repo's
-- FIRST DAY (816e9e3, 2026-05-16) and reached 14 load-bearing sites — 3
-- independent COALESCE fallbacks, 7 DEFAULT parameters, 2 bundle literals and a
-- Go const. Nobody chose it; it was an EXAMPLE that propagated by default-value
-- copying, because a default is not a declaration and no gate can refuse one.
--
-- MEASURED CONSEQUENCE, on a fresh boot of the current release: 24 sealed
-- instances in urn:ckp:demo/instances declaring (M2, producedBy) that they are
-- governed by urn:ckp:demo/kernel/ck — a graph with ZERO quads. Facts citing a
-- jurisdiction that was never germinated. Sealed correctly, by a substrate doing
-- exactly what it was told, against a kernel nobody created.
--
-- THIS RELEASE, in one sentence: absent means ABSENT.
--   * clause 0 in _project_explain — no kernel named resolves to NO PROJECT,
--     never to a borrowed name. Also CONSOLIDATES: surface_check and
--     integrity_check carried their OWN copies of the fallback, so the two verbs
--     a caller uses to ask "am I healthy" resolved the project independently of
--     the resolver everything else used. The comment above the first fallback
--     claimed this consolidation was already done ("in one place… a single edit
--     instead of twelve"); it was not. Now it is.
--   * _composed_shapes — with no kernel there is nothing to union into core, so
--     the surface IS core. Core-only is a complete, correct state, not a fault.
--   * _derived_stamps — sealing REFUSES, naming M2: a fact must say whose law
--     governs it. Reads, surface.declared, surface.typecheck and
--     instance.validate all continue to work core-only.
--
-- Gate: sql/test/s70_kernel_planes_agree.sql (extended with the default-state
-- claim) + s34 + the s4 suite. The negative control that matters: a NAMED kernel
-- with an empty graph must STILL report unhealthy — making core-only healthy
-- must not blind the real wipe detector.

CREATE OR REPLACE FUNCTION ckp._project_explain()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N       text := 'https://conceptkernel.org/ontology/v3.11/core#';
  -- ONE definition of "which project is this". Twelve call sites resolved it
  -- inline in two spellings that DISAGREED on the empty string: ckp.dispatch
  -- mapped '' to '', everything else mapped '' to 'demo' -- so an empty GUC
  -- sent the affordance lookup and the write to different kernels.
  --
  -- The 'demo' fallback is itself a real kernel name, which makes it a landing
  -- site for writes that belong to nobody. It lives HERE now, in one place, so
  -- it can be made fail-closed in a single edit instead of twelve.
  CANON   text := '^[a-z0-9]+(-[a-z0-9]+)*$';
  v_raw   text := NULLIF(current_setting('ckp.project', true), '');
  v_kid   text;
  v_hits  text[];
  v_ask   text;
BEGIN
  -- 0.4.79 — CLAUSE 0: NO KERNEL NAMED. This slot held 'demo' from the repo's
  -- first day (816e9e3, 2026-05-16) and propagated to 14 load-bearing sites: an
  -- EXAMPLE became infrastructure because no gate could refuse a default. It
  -- invented a jurisdiction, so facts sealed declaring themselves governed by
  -- urn:ckp:demo/kernel/ck -- a graph with ZERO quads, measured on a fresh boot
  -- of the current release. Now: absent means ABSENT. The law is still readable
  -- (surface.declared, surface.typecheck, instance.validate all work core-only);
  -- what refuses is SEALING, because M2 (producedBy) is not optional -- a fact
  -- must name whose law governs it. Not having germinated is a complete and
  -- correct state, not a fault.
  IF v_raw IS NULL THEN
    RETURN jsonb_build_object('project', NULL, 'clause',
      'clause 0 - no kernel named (ckp.project unset). The law is in force and readable; sealing refuses until a kernel is named, because a fact must say whose law governs it.',
      'hits', '[]'::jsonb);
  END IF;
  v_kid := 'urn:ckp:'||v_raw||'/kernel';
  -- 1. a CANONICAL spelling with its own sealed kernel wins outright. This is the
  --    common path and costs one indexless scan of a small table. The canonical
  --    guard is load-bearing: without it a non-canonical twin resolves to itself
  --    and the split it exists to close survives (measured — see above).
  IF v_raw ~ CANON AND EXISTS (SELECT 1 FROM ckp.instances i
              WHERE i.body->>'type' = N||'Kernel' AND i.body->>'@id' = v_kid) THEN
    RETURN jsonb_build_object('project', v_raw, 'clause',
      'clause 1 — canonical, and it carries its own sealed ckp:Kernel', 'hits', to_jsonb(v_hits));
  END IF;
  -- 2/3. resolve case-insensitively against the CANONICAL sealed kernels — the
  --      ones a germination today would have produced.
  SELECT array_agg(DISTINCT i.body->>'@id') INTO v_hits
    FROM ckp.instances i
   WHERE i.body->>'type' = N||'Kernel'
     AND lower(i.body->>'@id') = lower(v_kid)
     AND regexp_replace(i.body->>'@id', '^urn:ckp:(.*)/kernel$', '\1') ~ CANON;
  IF v_hits IS NOT NULL AND array_length(v_hits, 1) = 1 THEN
    RETURN jsonb_build_object('project', regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel$', '\1'),
      'clause', 'clause 2 — resolved onto the one CANONICAL SEALED kernel that answers to this name',
      'hits', to_jsonb(v_hits));
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    -- RAISE takes only `%`; a `%L` here would print the value followed by a
    -- literal L. Format first, raise the formatted string. (Caught by the
    -- negative control, which is the argument for having written one.)
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s sealed kernels answer to it case-insensitively (%s). One kernel must have one spelling; resolve it by governance (seal a ckp:Supersession for the one that is not authoritative) rather than by guessing here.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 4. NO SEALED KERNEL — RESOLVE ONTO THE SPELLING THAT HAS SUBSTANCE.
  --
  -- 0.4.54, and this gap was exposed by pgRDF's own report, not by pgCK. The
  -- 0.4.51 rule resolved case only against SEALED kernels, so it closed the split
  -- for pgck — which happens to have one — and did NOTHING for a kernel that
  -- exists only as a GRAPH. Measured with pgCK's own project.resolve verb:
  --     pgrdf -> clause 4 -> pgrdf   (urn:ckp:pgrdf/kernel/ck EMPTY)
  --     pgRDF -> clause 5 -> pgRDF   (urn:ckp:pgRDF/kernel/ck, 25 triples, their doctrine)
  -- sealedKernelsMatching [] for both. Two spellings, two surfaces, and the fix
  -- shipped to end exactly that could not see it. A rule that only works for
  -- kernels shaped like mine is not a rule.
  --
  -- The ordering principle is NOT "prefer the canonical spelling" — it is PREFER
  -- THE SPELLING WITH SUBSTANCE, sealed beating graph, because the substrate must
  -- derive from a fact rather than from a preference about names. Pointing pgrdf
  -- at its empty canonical graph would be canonically tidy and would lose their
  -- doctrine, which is the wrong trade every time.
  --
  -- Migration path, deliberately: the day a kernel seals a ckp:Kernel under its
  -- canonical name, clauses 1-2 take over and BOTH spellings resolve there. This
  -- clause retires itself; it is not a permanent tolerance.
  SELECT array_agg(DISTINCT g) INTO v_hits FROM (
    SELECT j->>'g' AS g FROM pgrdf.sparql(format($q$
      SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }
    $q$)) j
    WHERE lower(j->>'g') = lower(format('urn:ckp:%s/kernel/ck', v_raw))
  ) d;
  IF v_hits IS NOT NULL AND array_length(v_hits, 1) = 1 THEN
    RETURN jsonb_build_object('project', regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel/ck$', '\1'),
      'clause', 'clause 4 — no sealed kernel anywhere; resolved onto the one spelling whose kernel GRAPH has substance',
      'hits', to_jsonb(v_hits));
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s non-empty kernel graphs answer to it case-insensitively (%s), and none carries a sealed ckp:Kernel to break the tie. Seal a ckp:Kernel under the canonical spelling; that resolves it permanently.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 5. nothing behind any spelling. A canonical name is the germination path and
  --    MUST stay open, or kernel.germinate is unreachable for every project that
  --    does not exist yet.
  IF v_raw ~ CANON THEN
    RETURN jsonb_build_object('project', v_raw, 'clause',
      'clause 5 — canonical, nothing sealed or graphed behind it yet; the germination path stays open',
      'hits', '[]'::jsonb);
  END IF;
  -- 6. neither a seal nor a graph stands behind this name. Refuse with the slug,
  --    the same message germination gives, so the two doors teach one rule.
  RAISE EXCEPTION '%', format(
    'ckp._project: kernel id %L is not canonical, no sealed kernel carries it and no kernel graph stands behind it. A project name is lowercase, dashes optional, one transport segment — use %L. (ckp.germinate_kernel refuses the same name; this door now applies the same rule, so a fact can never be sealed into a project that could not be germinated.)',
    v_raw, ckp._slug(regexp_replace(v_raw, '^.*[:/]', '')));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._derived_stamps(p_subj text, p_type text, p_project text, p_participant text, p_shapes_graph integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_ep  int;
  v_shp text;
  v_giri text;
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF p_subj IS NULL OR p_type IS NULL THEN RETURN '{}'::jsonb; END IF;

  -- 0.4.79 -- M2 IS NOT OPTIONAL. producedBy names the kernel whose law governs
  -- this fact. With no kernel named this built 'urn:ckp:'||NULL||'/kernel/ck',
  -- and before clause 0 it built urn:ckp:demo/kernel/ck -- a jurisdiction that
  -- was never germinated. A fact governed by nobody is worse than a refused one.
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RAISE EXCEPTION 'ckp.seal: no kernel named, so this fact cannot carry M2 (producedBy) -- and a fact must say whose law governs it. The law IS loaded and readable: surface.declared, surface.typecheck and instance.validate all answer core-only. To seal, name your kernel: SELECT set_config(''ckp.project'', ''<your-kernel>'', true), or germinate one. (Until 0.4.79 this silently landed in the project ''demo'', whose kernel graph is empty.)';
  END IF;

  -- producedBy — the kernel that processed this instance. Server-derived.
  v_out := v_out || jsonb_build_object(N||'producedBy', 'urn:ckp:'||p_project||'/kernel/ck');

  -- createdBy — the resolved participant. Never from the payload; the caller's
  -- own claim was stripped before this ran.
  IF p_participant IS NOT NULL THEN
    v_out := v_out || jsonb_build_object(N||'createdBy', p_participant);
  END IF;

  -- sealedAtEpoch — the producing kernel's epoch at seal. Carried as a JSON
  -- number so a re-projection of the stored body yields xsd:integer, which is
  -- what InstanceShape declares.
  SELECT epoch INTO v_ep FROM ckp.kernel_epoch WHERE kernel = p_project;
  v_out := v_out || jsonb_build_object(N||'sealedAtEpoch', to_jsonb(COALESCE(v_ep,0)));

  -- conformsToShape — the declared shape that targets this type, resolved from the
  -- same graph the gate validates against. Absent => omitted rather than invented.
  IF p_shapes_graph IS NOT NULL THEN
    SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_shapes_graph;
    SELECT j->>'s' INTO v_shp FROM pgrdf.sparql(format($q$
        PREFIX sh: <http://www.w3.org/ns/shacl#>
        SELECT ?s WHERE { GRAPH <%s> { ?s sh:targetClass <%s> } } LIMIT 1
      $q$, v_giri, p_type)) j;
    IF v_shp IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(N||'conformsToShape', v_shp);
    END IF;
  END IF;
  RETURN v_out;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text DEFAULT 'demo'::text, p_exclude text DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION ckp.surface_check(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj   text := COALESCE(p_project, ckp._project());
  v_kiri   text;
  v_epoch  int;
  v_ep_iri text;
  v_pin_surf text;
  v_pin_src  text;
  v_comp   int;
  v_act_surf text;
  v_act_src  text;
  v_kquads int;
  v_shapes int;
  v_mods   jsonb := '[]'::jsonb;
  v_iri    text;
  v_n      int;
  v_find   jsonb := '[]'::jsonb;
BEGIN
  v_kiri  := 'urn:ckp:'||v_proj||'/kernel/ck';
  v_epoch := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);

  -- What the ledger says the surface was, at the epoch in force.
  SELECT i.body->>'@id', i.body->>(N||'surfaceDigest')
    INTO v_ep_iri, v_pin_surf
  FROM ckp.instances i
  WHERE i.body->>'type' = N||'Epoch'
    AND i.body->>(N||'producedBy') = v_kiri
    AND (i.body->>(N||'epoch'))::int = v_epoch
  ORDER BY i.ts_created DESC LIMIT 1;

  SELECT i.body->>(N||'sourceDigest') INTO v_pin_src
  FROM ckp.instances i
  WHERE i.body->>'type' = N||'Materialization'
    AND i.body->>(N||'producesEpoch') = v_ep_iri
  ORDER BY i.ts_created DESC LIMIT 1;

  -- What it is now.
  v_comp     := ckp._composed_shapes(v_proj);
  v_act_surf := ckp._surface_digest(v_comp);
  v_act_src  := ckp._surface_digest(pgrdf.add_graph(v_kiri));

  SELECT count(*) INTO v_kquads
    FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } }', v_kiri));
  SELECT count(*) INTO v_shapes
    FROM pgrdf.sparql(format('PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <%s> { ?s a sh:NodeShape } }',
                             (SELECT iri FROM pgrdf._pgrdf_graphs WHERE graph_id = v_comp)));

  -- Every adopted module: present and non-empty, or named as missing.
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(v_proj) LOOP
    SELECT count(*) INTO v_n
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } }', v_iri));
    v_mods := v_mods || jsonb_build_array(jsonb_build_object('iri', v_iri, 'quads', v_n, 'present', v_n > 0));
    IF v_n = 0 THEN
      v_find := v_find || jsonb_build_array('adopted module is ABSENT or EMPTY: '||v_iri);
    END IF;
  END LOOP;

  -- Findings. Each names what was measured, never a guess at the cause.
  IF v_kquads = 0 THEN
    v_find := v_find || jsonb_build_array(
      'kernel graph '||v_kiri||' is EMPTY — the enforcement surface is composed WITHOUT the '||
      'kernel''s own shapes. This is the 2026-08-10 wipe signature.');
  END IF;
  IF v_shapes = 0 THEN
    v_find := v_find || jsonb_build_array(
      'composed surface carries ZERO NodeShapes — every gate is vacuous; refuse to trust any conformance result');
  END IF;
  IF v_pin_surf IS NULL THEN
    v_find := v_find || jsonb_build_array(
      'no sealed ckp:Epoch for epoch '||v_epoch||' — the surface in force names no digest, so drift is undetectable (pre-governance state)');
  ELSIF v_pin_surf IS DISTINCT FROM v_act_surf THEN
    v_find := v_find || jsonb_build_array(
      'SURFACE DRIFT: the composed surface differs from the digest epoch '||v_epoch||' sealed. '||
      'Either the surface changed outside a governed apply (adoption, a direct graph write, or a wipe), '||
      'or an apply failed to reseal. Pinned '||left(v_pin_surf,12)||'… actual '||left(v_act_surf,12)||'…');
  END IF;
  IF v_pin_src IS NOT NULL AND v_pin_src IS DISTINCT FROM v_act_src THEN
    v_find := v_find || jsonb_build_array(
      'SOURCE DRIFT: the kernel graph differs from the sourceDigest its Materialization sealed. '||
      'Pinned '||left(v_pin_src,12)||'… actual '||left(v_act_src,12)||'…');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'kernel', v_proj,
    'epoch', v_epoch,
    'epoch_resource', v_ep_iri,
    'surface', jsonb_build_object('pinned', v_pin_surf, 'actual', v_act_surf,
                                  'match', v_pin_surf IS NOT DISTINCT FROM v_act_surf),
    'source',  jsonb_build_object('pinned', v_pin_src,  'actual', v_act_src,
                                  'match', v_pin_src IS NOT DISTINCT FROM v_act_src),
    'kernel_graph', jsonb_build_object('iri', v_kiri, 'quads', v_kquads, 'empty', v_kquads = 0),
    'composed_nodeshapes', v_shapes,
    'modules', v_mods,
    'findings', v_find,
    'healthy', jsonb_array_length(v_find) = 0);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.integrity_check(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj text := COALESCE(p_project, ckp._project());
  v_comp int;
  v_giri text;
  v_find jsonb := '[]'::jsonb;
  v_total int; v_unattr int; v_vac int; v_vac_new int;
  r record;
BEGIN
  v_comp := ckp._composed_shapes(v_proj);
  SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = v_comp;

  SELECT count(*) INTO v_total FROM ckp.instances;

  -- 1. ATTRIBUTION over sealed rows. InstanceShape requires createdBy; a stored
  -- row without it predates 0.4.33 or bypassed the seal. Named, not assumed.
  SELECT count(*) INTO v_unattr FROM ckp.instances
   WHERE NOT (body ? (N||'createdBy'));
  IF v_unattr > 0 THEN
    v_find := v_find || jsonb_build_array(
      v_unattr||' sealed row(s) carry no ckp:createdBy — unattributable work (pre-0.4.33 seals)');
  END IF;

  -- 2. VACUOUS SEALS. conformsToShape is omitted rather than invented when no
  -- shape targeted the candidate, so its absence IS the vacuity signal.
  -- Pre-governance rows (sealedAtEpoch 0) are SCARS: sealed before the root was in
  -- force, unfixable by construction (nothing is ever unsealed), and legitimate
  -- history under the S5 ruling — fence, never backfill. They are reported under
  -- `historical`, NOT as findings: a check that can never go green trains its
  -- reader to ignore it, which is how a real defect gets missed. A vacuous seal at
  -- epoch >= 1 is a live defect and IS a finding.
  SELECT count(*) INTO v_vac FROM ckp.instances
   WHERE NOT (body ? (N||'conformsToShape'))
     AND COALESCE((body->>(N||'sealedAtEpoch'))::int, 0) = 0;
  SELECT count(*) INTO v_vac_new FROM ckp.instances
   WHERE NOT (body ? (N||'conformsToShape'))
     AND COALESCE((body->>(N||'sealedAtEpoch'))::int, 0) > 0;
  IF v_vac_new > 0 THEN
    v_find := v_find || jsonb_build_array(
      v_vac_new||' row(s) sealed AT epoch >= 1 carry no ckp:conformsToShape — they passed a gate '||
      'that targeted nothing. Post-adoption vacuity is a defect, not history.');
  END IF;

  -- 3. G-1 PROPER: cross-node references the gate cannot check. Each is reported
  -- with its subject so the finding is actionable, never a bare count.
  FOR r IN
    SELECT i.id, i.body->>(N||'derivedBy') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Affordance' AND i.body ? (N||'derivedBy')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances m
                        WHERE m.body->>'type' = N||'Materialization'
                          AND m.body->>'@id' = i.body->>(N||'derivedBy'))
       AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                        WHERE s.body->>'type' = N||'Supersession'
                          AND s.body->>(N||'supersedes') = i.body->>'@id')
  LOOP
    v_find := v_find || jsonb_build_array(
      'DANGLING derivedBy: affordance '||r.id||' names '||r.ref||' — no sealed Materialization. '||
      'The root says a hand-registered action cannot hide; body locality means the gate cannot enforce it.');
  END LOOP;

  FOR r IN
    SELECT i.id, i.body->>(N||'inShape') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Affordance' AND i.body ? (N||'inShape')
       AND ckp._affordance_schema(i.body->>(N||'inShape'), v_comp) IS NULL
       -- withdrawal is a sealed act (Supersession), never a delete: a superseded
       -- affordance is out of force and must not keep raising.
       AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                        WHERE s.body->>'type' = N||'Supersession'
                          AND s.body->>(N||'supersedes') = i.body->>'@id')
  LOOP
    v_find := v_find || jsonb_build_array(
      'UNRESOLVABLE inShape: affordance '||r.id||' names '||r.ref||' — not in the composed surface, '||
      'so no input contract can be derived for it.');
  END LOOP;

  FOR r IN
    SELECT i.id, i.body->>(N||'adopts') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Adoption' AND i.body ? (N||'adopts')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances m
                        WHERE m.body->>'type' = N||'Module'
                          AND m.body->>'@id' = i.body->>(N||'adopts'))
  LOOP
    v_find := v_find || jsonb_build_array(
      'ADOPTION without a sealed Module: '||r.id||' adopts '||r.ref||' — the digest it claims to '||
      'pin is not on the ledger.');
  END LOOP;

  -- 4. The §4.5 worked examples: a Grant must target an Organ, a Membership must
  -- hold a Role. Zero rows today; the check exists so the first wrong one is seen.
  FOR r IN
    SELECT i.id, i.body->>(N||'permTarget') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Grant' AND i.body ? (N||'permTarget')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances o
                        WHERE o.body->>'@id' = i.body->>(N||'permTarget')
                          AND o.body->>'type' IN (N||'Organ', N||'CK', N||'TOOL', N||'DATA'))
  LOOP
    v_find := v_find || jsonb_build_array('GRANT targets a non-Organ: '||r.id||' -> '||r.ref);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj,
    'sealed_rows', v_total,
    'unattributed', v_unattr,
    'historical', jsonb_build_object('pre_governance_vacuous_seals', v_vac,
      'note', 'sealed before the root was in force; unfixable and legitimate — fence, never backfill'),
    'vacuous_seals_live', v_vac_new,
    'findings', v_find,
    'healthy', jsonb_array_length(v_find) = 0);
END;
$function$
;
