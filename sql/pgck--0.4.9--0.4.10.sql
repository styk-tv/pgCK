-- ============================================================================
-- pgck 0.4.9 -> 0.4.10 — v0.5 roadmap T3: per-kernel sealed transition map
-- ============================================================================
-- `ckp.transition` gated on ONE global `ckp.config('transition_map')` — the §4
-- concretion. T3 makes the transition map a per-kernel SEALED fact: the governance
-- op `set_transition_map` writes `<targetClass> ckp:allowsTransition [ ckp:fromState
-- "x" ; ckp:toState "y" ]` triples into the kernel graph (via the v0.4.5 _graph_apply
-- machinery), and `ckp.transition` reads the instance type's own map.
--
-- Three changes:
--   1. ckp._op_to_ttl — translate `set_transition_map {targetClass, map:{from:[to…]}}`
--      into the ckp:allowsTransition triples (state names validated; injection-safe).
--   2. ckp.apply_shape_ttl — extend the meta-fence to admit the THREE governance
--      transition predicates (allowsTransition/fromState/toState) alongside rdf/rdfs/
--      owl/sh. The op TTL is pgCK-built + field-validated; the fence stays closed to
--      every other predicate, so no instance data can ride this path.
--   3. ckp.transition — when the type has a sealed map, IT governs (per-kernel, no
--      global bleed); a type with no sealed map keeps the global config (back-compat).
--
-- Exit test: sql/test/s44_transition_map.sql — govern-set a Ship map
-- (planned→[crewed], crewed→[deployed]); transition(ship,crewed) ok, (ship,deployed)
-- from planned rejected; a different kernel's Task map is independent of the global.
-- ============================================================================

-- ---- ckp._op_to_ttl — + set_transition_map ----------------------------------
CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $o2t$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';            -- state names (no quote/space)
  v_op       text := p_prop->>(C||'proposalOp');
  v_detail   jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_class    text;
  v_path     text;
  v_min      int;
  v_dtype    text;
  v_dt_line  text := '';
  v_map      jsonb;
  v_fs       text;
  v_ts       text;
  v_ttl      text;
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
    RETURN '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '[ a sh:NodeShape ; sh:targetClass <'||v_class||'> ; '||
           'sh:property [ sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' ] ] .';

  ELSIF v_op = 'add_class' THEN
    v_class := COALESCE(v_detail->>'class', v_detail->>'targetClass', p_prop->>(C||'about'));
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_class: class must be an IRI, got %', v_class; END IF;
    RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
           '<'||v_class||'> a owl:Class .';

  ELSIF v_op = 'set_transition_map' THEN
    v_class := v_detail->>'targetClass';
    v_map   := v_detail->'map';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'set_transition_map: targetClass must be an IRI, got %', v_class; END IF;
    IF v_map IS NULL OR jsonb_typeof(v_map) <> 'object' THEN
      RAISE EXCEPTION 'set_transition_map: map must be an object {from:[to,…]}'; END IF;
    v_ttl := '@prefix ckp: <'||C||'> .'||chr(10);
    FOR v_fs IN SELECT jsonb_object_keys(v_map) LOOP
      IF v_fs !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad from-state %', v_fs; END IF;
      IF jsonb_typeof(v_map->v_fs) <> 'array' THEN
        RAISE EXCEPTION 'set_transition_map: map[%] must be an array of to-states', v_fs; END IF;
      FOR v_ts IN SELECT jsonb_array_elements_text(v_map->v_fs) LOOP
        IF v_ts !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad to-state %', v_ts; END IF;
        v_ttl := v_ttl || '<'||v_class||'> ckp:allowsTransition '||
                 '[ ckp:fromState "'||v_fs||'" ; ckp:toState "'||v_ts||'" ] .'||chr(10);
      END LOOP;
    END LOOP;
    RETURN v_ttl;

  END IF;
  -- Ops without a shape projection yet (modify_shape_constraint, set_quorum,
  -- set_materialize_policy) leave the graph unchanged here; add_affordance with a query
  -- is handled by ckp.apply's register step. Translators land as each is built.
  RETURN NULL;
END;
$o2t$;
ALTER FUNCTION ckp._op_to_ttl(jsonb) OWNER TO ck_substrate;

-- ---- ckp.apply_shape_ttl — fence admits the governance transition vocab --------
CREATE OR REPLACE FUNCTION ckp.apply_shape_ttl(p_ttl text, p_project text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ast$
DECLARE
  C             text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_scratch_iri text := 'urn:ckp:apply:'||pg_backend_pid();
  v_scratch     int;
  v_kernel      int;
  v_quads       bigint;
  v_forbidden   jsonb;
BEGIN
  v_scratch := pgrdf.add_graph(v_scratch_iri);
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:apply#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'detail', SQLERRM);
  END;

  -- META-FENCE — admit ontology-meta predicates (rdf/rdfs/owl/sh) PLUS the three sealed
  -- governance transition predicates (allowsTransition/fromState/toState). Every other
  -- predicate (instance data, foreign triples) is fence-rejected. The op TTL is pgCK-built
  -- and field-validated; this fence is the defence-in-depth backstop.
  SELECT jsonb_agg(DISTINCT j->>'p') INTO v_forbidden
  FROM pgrdf.sparql(format($q$
    SELECT ?p WHERE { GRAPH <%s> { ?s ?p ?o }
      FILTER( !STRSTARTS(STR(?p), "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2000/01/rdf-schema#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2002/07/owl#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/ns/shacl#")
           && STR(?p) != "%sallowsTransition"
           && STR(?p) != "%sfromState"
           && STR(?p) != "%stoState" ) }
  $q$, v_scratch_iri, C, C, C)) j;
  IF v_forbidden IS NOT NULL THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'fence_violation', 'forbidden_predicates', v_forbidden);
  END IF;

  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  PERFORM ckp._graph_apply(v_scratch, v_kernel);
  PERFORM pgrdf.materialize(v_kernel);
  PERFORM pgrdf.clear_graph(v_scratch);
  RETURN jsonb_build_object('ok', true, 'applied_quads', v_quads, 'kernel_graph', v_kernel);
END;
$ast$;
ALTER FUNCTION ckp.apply_shape_ttl(text, text) OWNER TO ck_substrate;

-- ---- ckp.transition — read the per-kernel sealed map (global fallback) ---------
CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $trans$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.8/core#';
  N        text := 'https://conceptkernel.org/ontology/v3.7/';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_proj   text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';
  v_body   jsonb; v_from text; v_type text; v_allowed jsonb; v_has_map boolean; v_src text;
BEGIN
  IF v_to IS NULL OR v_to !~ v_state_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  v_type := v_body->>'type';
  v_from := COALESCE(v_body->>(N||'lifecycle_state'), v_body->>'state', v_body->>(C||'lifecycle_state'), 'planned');

  -- T3: does the instance's TYPE carry a sealed transition map in the kernel graph?
  v_has_map := (v_type IS NOT NULL AND v_type ~ '^[A-Za-z]' AND EXISTS (
    SELECT 1 FROM pgrdf.sparql(format($q$
      PREFIX ckp: <%s>
      SELECT ?t WHERE { GRAPH <urn:ckp:%s/kernel/ck> { <%s> ckp:allowsTransition ?t } } LIMIT 1
    $q$, C, v_proj, v_type)) j));

  IF v_has_map THEN
    -- per-kernel sealed map governs (no global bleed). from must be a safe state to bind.
    v_src := 'kernel';
    IF v_from !~ v_state_re OR NOT EXISTS (
      SELECT 1 FROM pgrdf.sparql(format($q$
        PREFIX ckp: <%s>
        SELECT ?t WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
          <%s> ckp:allowsTransition ?t . ?t ckp:fromState "%s" ; ckp:toState "%s" } }
      $q$, C, v_proj, v_type, v_from, v_to)) j) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'source', v_src);
    END IF;
  ELSE
    -- fallback: the global config map (back-compat).
    v_src := 'config';
    v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
    IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'allowed', v_allowed, 'source', v_src);
    END IF;
  END IF;

  v_body := v_body || jsonb_build_object(N||'lifecycle_state', v_to, 'state', v_to);
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to,
                            'source', v_src, 'verified', ckp.verify(v_id));
END;
$trans$;
ALTER FUNCTION ckp.transition(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.transition(jsonb) IS
  'T3 (v0.4.10): instance.transition gated on the instance type''s per-kernel SEALED transition map '
  '(ckp:allowsTransition triples in the kernel graph, set via the governance plane); a type with no '
  'sealed map falls back to the global ckp.config map. Reads v3.7 lifecycle_state, writes both.';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
