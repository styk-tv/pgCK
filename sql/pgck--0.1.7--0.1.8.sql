-- pgCK 0.1.7 -> 0.1.8 upgrade
-- CKB-4: SHACL gate inside ckp.seal() — projection now scratches new triples
-- into a private graph, validates against the project board's shapes, and
-- ROLLS BACK the whole seal transaction (RAISE EXCEPTION) on conforms=false.
-- Pre-flight asserts ckp.shapes_self_test(project) so stale ontology mounts
-- fail fast rather than silently passing a vacuous SHACL check.
-- Spec: _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §5.

CREATE OR REPLACE FUNCTION ckp.project_links(
  p_project text,
  p_instance_id text,
  p_body jsonb
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_type        text := p_body->>'type';
  v_short_type  text;
  v_board_iri   text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g     bigint;
  v_scratch_iri text;
  v_scratch_g   bigint;
  v_id          text;
  v_goal_id     text;
  v_kernel      text;
  v_label       text;
  v_subject     text;
  v_ttl         text;
  v_validation  jsonb;
  v_results     jsonb;
  v_added       bigint := 0;
BEGIN
  -- Class detection: only Task and Goal project link triples in v0.1.
  IF v_type ILIKE '%/Task' OR v_type = 'ckp:Task' THEN
    v_short_type := 'Task';
  ELSIF v_type ILIKE '%/Goal' OR v_type = 'ckp:Goal' THEN
    v_short_type := 'Goal';
  ELSE
    RETURN 0;
  END IF;

  -- Build the Turtle that represents this instance's link triples.
  IF v_short_type = 'Task' THEN
    v_id      := p_body->>'https://conceptkernel.org/ontology/v3.7/task_id';
    v_goal_id := p_body->>'https://conceptkernel.org/ontology/v3.7/part_of_goal';
    v_kernel  := p_body->>'https://conceptkernel.org/ontology/v3.7/target_kernel';

    -- Bodies missing any required link field reach the SHACL gate below
    -- with an empty/partial scratch graph — the gate catches them and
    -- rolls back the seal. That keeps the rejection path single-sourced.
    v_subject := 'ckp://Task#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '<%s> a ckp:Task',
      v_subject);

    IF v_goal_id IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:part_of_goal <ckp://Goal#%s>',
        ckp.urn_normalise(v_goal_id));
    END IF;
    IF v_kernel IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:target_kernel <ckp://Kernel#%s>',
        ckp.urn_normalise(v_kernel));
    END IF;
    v_ttl := v_ttl || ' .';

  ELSIF v_short_type = 'Goal' THEN
    v_id    := p_body->>'https://conceptkernel.org/ontology/v3.7/goal_id';
    v_label := p_body->>'https://conceptkernel.org/ontology/v3.7/title';

    v_subject := 'ckp://Goal#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp:  <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> . '
      || '<%s> a ckp:Goal',
      v_subject);

    IF v_label IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; rdfs:label "%s"',
        replace(v_label, '"', '\"'));
    END IF;
    v_ttl := v_ttl || ' .';
  END IF;

  -- CKB-4 pre-flight: refuse to validate if the project board's shapes
  -- are missing (stale /ontology/ mount, project never imported the
  -- modules, etc.). shapes_self_test RAISES on missing shape — propagate.
  PERFORM ckp.shapes_self_test(p_project);

  -- Project into a private scratch graph so the gate decides whether the
  -- triples ever land in the board. add_graph is get-or-create; clear
  -- before parse so a duplicate seal (same id) doesn't pollute.
  v_board_g     := pgrdf.add_graph(v_board_iri);
  v_scratch_iri := format('urn:ckp:%s/seal-scratch/%s', p_project, p_instance_id);
  v_scratch_g   := pgrdf.add_graph(v_scratch_iri);
  PERFORM pgrdf.clear_graph(v_scratch_g);
  PERFORM pgrdf.parse_turtle(v_ttl, v_scratch_g, 'urn:ckp:projection#');

  -- SHACL gate: validate scratch against the board's shapes. Native mode
  -- (pgrdf 0.5.1) is sufficient — see _WIP/NOTIFIES.pgRDF.0.5.1.shacl-
  -- mincount-permissive-RESPONSE.md for the verified semantics.
  v_validation := pgrdf.validate(v_scratch_g, v_board_g);

  IF NOT (v_validation->>'conforms')::boolean THEN
    v_results := v_validation->'results';
    PERFORM pgrdf.drop_graph(v_scratch_g);
    RAISE EXCEPTION 'ckp.seal: SHACL gate rejected % % — % violation(s); first: %',
      v_short_type,
      p_instance_id,
      jsonb_array_length(v_results),
      v_results->0->>'sourceConstraintComponent';
  END IF;

  -- Validation passed: commit the same Turtle into the board graph and
  -- discard the scratch.
  v_added := pgrdf.parse_turtle(v_ttl, v_board_g, 'urn:ckp:projection#');
  PERFORM pgrdf.drop_graph(v_scratch_g);

  RETURN v_added::int;
END;
$$;

COMMENT ON FUNCTION ckp.project_links(text, text, jsonb) IS
  'CKB-4/CKB-5: validate-then-commit projection of Task/Goal link triples. RAISES on SHACL non-conformance (rolls back caller seal).';

-- ============================================================================
-- §2. CKB-4 — fix ckp.shapes_self_test ASK result parsing
-- ============================================================================
-- pgrdf.sparql returns ASK results as `{"_ask": "true"}` (string), not
-- `{"boolean": true}`. The original (v0.1.7) self-test parsed the wrong key,
-- so it always reported shapes as missing even when they were present —
-- masking the real CKB-4 gate. This replacement reads `_ask` correctly.

CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text DEFAULT 'demo')
RETURNS TABLE (shape_class text, target_class text, present boolean)
LANGUAGE plpgsql AS $$
DECLARE
  v_board_iri text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g   bigint := pgrdf.graph_id(v_board_iri);
  v_q         text;
  v_row       record;
  v_ask       text;
  v_missing   text[] := ARRAY[]::text[];
BEGIN
  IF v_board_g IS NULL THEN
    RAISE EXCEPTION 'ckp.shapes_self_test: project board graph % not present; call ckp.import_module(''task'', %s) and ckp.import_module(''goal'', %s) first',
      v_board_iri, quote_literal(p_project), quote_literal(p_project);
  END IF;

  FOR v_row IN
    SELECT * FROM (VALUES
      ('ckp:TaskShape', 'ckp:Task'),
      ('ckp:GoalShape', 'ckp:Goal')
    ) AS expected(shape, target)
  LOOP
    v_q := format(
      'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
       PREFIX sh:  <http://www.w3.org/ns/shacl#>
       PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
       ASK FROM <%s>
       WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass %s }',
      v_board_iri, v_row.target);

    shape_class  := v_row.shape;
    target_class := v_row.target;
    SELECT j->>'_ask' INTO v_ask FROM pgrdf.sparql(v_q) j LIMIT 1;
    present := COALESCE(v_ask = 'true', false);
    IF NOT present THEN
      v_missing := array_append(v_missing, v_row.shape);
    END IF;
    RETURN NEXT;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'ckp.shapes_self_test: missing % shape(s) in %; check /ontology mount is current',
      v_missing, v_board_iri;
  END IF;
END;
$$;
