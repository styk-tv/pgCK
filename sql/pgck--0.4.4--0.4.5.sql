-- ============================================================================
-- pgck 0.4.4 -> 0.4.5 — Tier 2 (2/3): governance _graph_apply (the EFFECT)
-- ============================================================================
-- The single biggest honesty gap in the v3.9 epoch: until this file, a passed
-- Proposal advanced the kernel epoch and sealed an "applied" record but NEVER
-- mutated the kernel's type. "Evolve the type via consensus" produced an audit
-- trail with no shape change.
--
-- This file wires the last hop of v3.9 §5.2. All the pieces already shipped:
--   * ckp.propose_change seals a typed op-set (add_property, add_class, …) as a
--     ckp:Proposal{pending} (sql/pgck--0.3.3--0.3.4.sql).
--   * ckp.stage_ttl meta-fences a Turtle payload (rdf/rdfs/owl/sh predicates only).
--   * ckp._graph_apply wraps pgrdf.copy_graph(src,dst) (sql/pgck--0.2.3--0.2.4.sql).
--   * ckp.bump_epoch advances the epoch + clears the plan cache.
-- What was missing was the TRANSLATOR that turns a passed op into staged shape-TTL
-- and copies it into the project kernel graph. Two new functions provide it, and
-- ckp.apply is redefined to call them BEFORE the epoch bump.
--
-- Injection safety is double-fenced: ckp._op_to_ttl validates every interpolated
-- value as an IRI / integer (no quote/space/newline can reach the TTL), and
-- ckp.apply_shape_ttl re-parses through the engine + admits only ontology-meta
-- predicates (the same fence as stage_ttl). The caller never authors raw Turtle —
-- they author a typed op; pgCK builds the Turtle.
--
-- Exit test: sql/test/s39_graph_apply_type_evolution.sql — create a Ship (seals,
-- unshaped) → propose+vote+apply add_property(crew_size, minCount 1) → the SAME
-- create is now REJECTED → with crew_size it seals. The type changed via consensus.
-- ============================================================================

-- ---- ckp._op_to_ttl — translate a passed Proposal op into SHACL shape TTL ----
-- Returns the Turtle to copy into the kernel graph, or NULL for ops that carry no
-- shape change (those still get the epoch bump + applied seal, unchanged). RAISEs on
-- a malformed shape op so ckp.apply reports graph_apply_failed rather than sealing a
-- no-op as a type change.
CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $o2t$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';   -- same gate as propose_change.about
  v_op       text := p_prop->>(C||'proposalOp');
  v_detail   jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_class    text;
  v_path     text;
  v_min      int;
  v_dtype    text;
  v_dt_line  text := '';
BEGIN
  IF v_op = 'add_property' THEN
    v_class := v_detail->>'targetClass';
    v_path  := v_detail->>'path';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: targetClass must be an IRI, got %', v_class; END IF;
    IF v_path IS NULL OR v_path !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: path must be an IRI, got %', v_path; END IF;
    BEGIN
      v_min := COALESCE((v_detail->>'minCount')::int, 1);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'add_property: minCount must be an integer, got %', v_detail->>'minCount'; END;
    v_dtype := v_detail->>'datatype';
    IF v_dtype IS NOT NULL THEN
      IF v_dtype !~ v_iri_re THEN RAISE EXCEPTION 'add_property: datatype must be an IRI, got %', v_dtype; END IF;
      v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
    END IF;
    -- A fresh NodeShape (blank node) targeting the class; copy_graph UNIONs it with any
    -- existing shape for the same class, so the property is ADDED, not replaced.
    RETURN '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '[ a sh:NodeShape ; sh:targetClass <'||v_class||'> ; '||
           'sh:property [ sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' ] ] .';

  ELSIF v_op = 'add_class' THEN
    v_class := COALESCE(v_detail->>'class', v_detail->>'targetClass', p_prop->>(C||'about'));
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_class: class must be an IRI, got %', v_class; END IF;
    RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
           '<'||v_class||'> a owl:Class .';

  END IF;
  -- Ops with no shape projection yet (modify_shape_constraint, add_affordance,
  -- set_transition_map, set_quorum, set_materialize_policy) leave the graph unchanged
  -- here; they still get the epoch bump + applied seal. Translators land as each is built.
  RETURN NULL;
END;
$o2t$;
ALTER FUNCTION ckp._op_to_ttl(jsonb) OWNER TO ck_substrate;

-- ---- ckp.apply_shape_ttl — stage, meta-fence, copy into the kernel graph -----
CREATE OR REPLACE FUNCTION ckp.apply_shape_ttl(p_ttl text, p_project text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ast$
DECLARE
  v_scratch_iri text := 'urn:ckp:apply:'||pg_backend_pid();
  v_scratch     int;
  v_kernel      int;
  v_quads       bigint;
  v_forbidden   jsonb;
BEGIN
  -- 1. STAGE — engine-parse into a scratch graph (no SQL string-building reaches the parser).
  v_scratch := pgrdf.add_graph(v_scratch_iri);
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:apply#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'detail', SQLERRM);
  END;

  -- 2. META-FENCE — admit only ontology-meta predicates (rdf/rdfs/owl/sh); reject any
  --    instance-data or foreign triple (identical fence to ckp.stage_ttl).
  SELECT jsonb_agg(DISTINCT j->>'p') INTO v_forbidden
  FROM pgrdf.sparql(format($q$
    SELECT ?p WHERE { GRAPH <%s> { ?s ?p ?o }
      FILTER( !STRSTARTS(STR(?p), "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2000/01/rdf-schema#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2002/07/owl#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/ns/shacl#") ) }
  $q$, v_scratch_iri)) j;
  IF v_forbidden IS NOT NULL THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'fence_violation', 'forbidden_predicates', v_forbidden);
  END IF;

  -- 3. APPLY — copy the staged shape into the project's kernel graph (the SAME graph
  --    ckp.seal reads required props from), materialize, drop the scratch. One txn.
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));  -- get-or-create by IRI
  PERFORM ckp._graph_apply(v_scratch, v_kernel);                          -- pgrdf.copy_graph
  PERFORM pgrdf.materialize(v_kernel);
  PERFORM pgrdf.clear_graph(v_scratch);
  RETURN jsonb_build_object('ok', true, 'applied_quads', v_quads, 'kernel_graph', v_kernel);
END;
$ast$;
ALTER FUNCTION ckp.apply_shape_ttl(text, text) OWNER TO ck_substrate;

-- ---- ckp.apply — now mutates the kernel shape (step 4a), then bumps the epoch ---
CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $apply$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_about     text := p_payload->>'about';   -- the Proposal @id (IRI)
  v_proj      text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_prop      jsonb;
  v_pid       text;
  v_quorum    int;
  v_approvals int;
  v_epoch     int;
  v_new_body  jsonb;
  v_ttl       text;
  v_ga        jsonb;
  v_applied   jsonb := jsonb_build_object('graph_changed', false);
BEGIN
  -- 1. field gate.
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  -- 2. the Proposal must exist + still be pending.
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 3. QUORUM GATE — COUNT approvals vs the Proposal's sealed requiresQuorum.
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  -- 4a. GRAPH APPLY (the v3.9 §5.2 EFFECT) — translate the op into the kernel graph.
  --     A shape-affecting op is staged, meta-fenced, and copied into urn:ckp:<proj>/kernel/ck
  --     so the NEXT seal is constrained by the new shape. Non-shape ops are a no-op here.
  BEGIN
    v_ttl := ckp._op_to_ttl(v_prop);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_translate_failed', 'detail', SQLERRM);
  END;
  IF v_ttl IS NOT NULL THEN
    v_ga := ckp.apply_shape_ttl(v_ttl, v_proj);
    IF (v_ga->>'ok') IS DISTINCT FROM 'true' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'graph_apply_failed', 'detail', v_ga);
    END IF;
    v_applied := jsonb_build_object('graph_changed', true, 'applied_quads', v_ga->'applied_quads');
  END IF;

  -- 4b. CASCADE (one txn). _recompile + epoch advance, then mark the Proposal applied.
  v_epoch := ckp.bump_epoch('pgCK');   -- recompile plans + pgrdf.plan_cache_clear() + epoch++

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_prop->>(C||'proposalOp'), 'approvals', v_approvals,
                            'applied', v_applied,
                            'verified', ckp.verify(v_pid));
END;
$apply$;

COMMENT ON FUNCTION ckp.apply(jsonb) IS
  'CI-D-3 + Tier 2 (v0.4.5): apply a quorum-satisfied Proposal — translate its op into the kernel '
  'graph (the §5.2 graph_apply EFFECT, for shape ops), advance the epoch (recompile + cache clear), '
  'and seal the Proposal applied, all-or-nothing. Below quorum -> quorum_not_met (no change).';

ALTER FUNCTION ckp.apply(jsonb) OWNER TO ck_substrate;

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
