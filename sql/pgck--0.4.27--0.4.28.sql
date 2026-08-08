-- pgck 0.4.27 -> 0.4.28
--
-- v3.11 ADOPTION (pgCK#41, carrying #31's re-point). One atomic act, per
-- PASS-17: the namespace and the root move together or not at all — a
-- namespace half-move conforms=true in BOTH directions (PASS-10, PASS-17),
-- silently, because an entry typed in one namespace is targeted by no shape
-- in the other.
--
-- This script re-points every function that embeds the ontology namespace to
-- https://conceptkernel.org/ontology/v3.11/core#, reconciles the bench-proven
-- ckp.validate (materialize before validate — entailment is per-graph and
-- pgrdf.validate does not entail), and adds ckp._derived_stamp_ttl: the four
-- substrate-derived properties ckp:InstanceShape requires (producedBy,
-- createdBy, sealedAtEpoch, conformsToShape) are now derived INTO the
-- candidate ckp.seal validates, instead of after the gate — which is the #41
-- defect: on the v3.11 root every Instance-classed seal failed by
-- construction.
--
-- Bodies below are extracted VERBATIM from sql/pgck-baseline.sql at this
-- version, so CREATE EXTENSION and ALTER EXTENSION UPDATE produce identical
-- catalogs. Root adoption itself is operational, not DDL: after this update,
-- CALL ckp.boot('/ontology/core.ttl') loads the e5f7d1e5 root (delivered in
-- ontology/, sha256 sidecar alongside).

CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.11/core#';
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
$function$
;

CREATE OR REPLACE FUNCTION ckp._derived_stamp_ttl(p_subj text, p_type text, p_project text, p_participant text, p_shapes_graph integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_ep  int;
  v_shp text;
  v_ttl text := '';
  v_giri text;
BEGIN
  IF p_subj IS NULL OR p_type IS NULL THEN RETURN ''; END IF;

  -- producedBy — the kernel that processed this instance. Server-derived.
  v_ttl := v_ttl || '<'||p_subj||'> <'||N||'producedBy> <urn:ckp:'||p_project||'/kernel/ck> .'||chr(10);

  -- createdBy — the verified participant, already resolved. Never from the payload.
  IF p_participant IS NOT NULL THEN
    v_ttl := v_ttl || '<'||p_subj||'> <'||N||'createdBy> <'||p_participant||'> .'||chr(10);
  END IF;

  -- sealedAtEpoch — the producing kernel's epoch at seal.
  SELECT epoch INTO v_ep FROM ckp.kernel_epoch WHERE kernel = p_project;
  v_ttl := v_ttl || '<'||p_subj||'> <'||N||'sealedAtEpoch> '||COALESCE(v_ep,0)::text||' .'||chr(10);

  -- conformsToShape — the declared shape that targets this type, resolved from the
  -- same graph the gate validates against. Absent => omitted rather than invented.
  IF p_shapes_graph IS NOT NULL THEN
    SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_shapes_graph;
    SELECT j->>'s' INTO v_shp FROM pgrdf.sparql(format($q$
        PREFIX sh: <http://www.w3.org/ns/shacl#>
        SELECT ?s WHERE { GRAPH <%s> { ?s sh:targetClass <%s> } } LIMIT 1
      $q$, v_giri, p_type)) j;
    IF v_shp IS NOT NULL THEN
      v_ttl := v_ttl || '<'||p_subj||'> <'||N||'conformsToShape> <'||v_shp||'> .'||chr(10);
    END IF;
  END IF;
  RETURN v_ttl;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_about     text := p_payload->>'about';
  v_proj      text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_prop      jsonb;
  v_pid       text;
  v_op        text;
  v_quorum    int;
  v_approvals int;
  v_epoch     int;
  v_new_body  jsonb;
  v_ttl       text;
  v_ga        jsonb;
  v_applied   jsonb := jsonb_build_object('graph_changed', false);
BEGIN
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  v_op := v_prop->>(C||'proposalOp');

  -- 4a. GRAPH APPLY (shape ops) — translate the op into the kernel graph (the §5.2 EFFECT).
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

  -- 4b. CASCADE — _recompile + epoch advance.
  v_epoch := ckp.bump_epoch('pgCK');

  -- 4c. QUERY AFFORDANCE (Tier 2 3/3b) — an add_affordance carrying query text is compiled into
  --     ckp.plans + registered plane='query', keyed to the new epoch (governed, sealed).
  IF v_op = 'add_affordance' AND (v_prop->'proposalDetail' ? 'query') THEN
    BEGIN
      PERFORM ckp.register_query_affordance(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('query_affordance', v_prop->'proposalDetail'->>'verb');
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'affordance_register_failed', 'detail', SQLERRM);
    END;
  END IF;

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'applied', v_applied,
                            'verified', ckp.verify(v_pid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.apply_shape_ttl(p_ttl text, p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C             text := 'https://conceptkernel.org/ontology/v3.11/core#';
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
$function$
;

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'https://conceptkernel.org/ontology/v3.7/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  req    jsonb := p_payload->'req';
  res    jsonb;
  v_proj text := COALESCE(current_setting('ckp.project', true), 'demo');
  v_idk  text := COALESCE(current_setting('ckp.identity_key', true), 'pgck-localhost');
  v_canon  text;   -- CI-B-2: canonical instance.* name (registry lookup key)
  v_aff    jsonb;  -- CI-B-1: the sealed affordance row (the registry IS the routing authority)
  v_legacy text;   -- CI-B-2: the legacy handler name (alias window)
BEGIN
  PERFORM set_config('ckp.project', v_proj, false);
  PERFORM set_config('ckp.identity_key', v_idk, false);

  -- CI-B-1/B-2 — the sealed registry is the SOLE routing authority. Resolve the canonical
  -- name + its sealed affordance row; an unregistered verb fails typed (unknown_affordance)
  -- with zero payload evaluation (no fallthrough); a delegate=true row is the Tier-2 tool
  -- seam; governance-plane verbs never execute here (proposal/vote/apply — CI-D). Otherwise
  -- resolve the legacy handler name (alias window) so the CASE below is unchanged and v0.3.0
  -- web2 keeps working.
  v_canon := ckp.verb_canon(p_verb);
  v_aff   := ckp.registry_lookup('pgCK', v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable',
      'plane', 'governance', 'verb', p_verb, 'canonical', v_canon)
      || jsonb_build_object('req', req);
  -- Tier 2 (3/3b): a governed query affordance (SPARQL text sealed via the governance plane,
  -- compiled into ckp.plans at apply) routes here. The caller binds typed params only; the query
  -- text is the kernel's OWN sealed fact, never caller input.
  ELSIF v_aff->>'plane' = 'query' THEN
    RETURN ckp.run_query_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  -- Scoring-loop layer 3: a governed DERIVED-read affordance ({formula, scope} sealed via the
  -- governance plane, compiled into ckp.plans at apply) routes here. The caller binds only the
  -- concept; the formula is the kernel's OWN sealed fact. Returns the band-less {ok, value,
  -- scored, freshness} envelope — the role-floor-reachable read surface the scoring client calls.
  ELSIF v_aff->>'plane' = 'derived' THEN
    RETURN ckp.run_derived_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  END IF;
  -- CI-E-5: instance.query is the typed derived-QueryShape read (the legacy instances.list alias
  -- keeps its list behavior below — routed by the ORIGINAL verb, not the shared canonical).
  IF p_verb = 'instance.query' THEN
    RETURN ckp.query(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.reach' THEN
    RETURN ckp.reach(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.transition' THEN
    RETURN ckp.transition(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.snapshot' THEN
    RETURN ckp.snapshot(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'concept.match' THEN
    RETURN ckp.concept_match(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.explain' THEN
    RETURN ckp.explain(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.retire' THEN
    RETURN ckp.retire(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.validate' THEN
    RETURN ckp.validate_instance(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 (v0.4.4): generic typed create. A uniform {type:<class IRI>, …fields} body
  -- routes to the §4 generic path, which seals it against the kernel's OWN declared shape.
  -- The discriminator is a TOP-LEVEL `type`: the legacy concretion forms carry no top-level
  -- `type` (task.create -> {task:{…}}, kernel.create -> {name:…}). `name` is NOT a usable
  -- discriminator here — it is a perfectly ordinary property on a generic type — so a `{task}`
  -- body still wins (the established concretion path) but everything else with a `type` is generic.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type')
        AND NOT (p_payload ? 'task') THEN
    RETURN ckp.create_typed(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 / v0.5 T4: generic typed update. instance.update with a `patch` sub-object patches
  -- by the type's declared properties (re-sealed); the legacy flat {id,…fields} form falls
  -- through to verb_to_legacy -> task.update.
  ELSIF p_verb = 'instance.update' AND (p_payload ? 'patch') THEN
    RETURN ckp.update_typed(p_payload) || jsonb_build_object('req', req);
  END IF;
  v_legacy := ckp.verb_to_legacy(p_verb, p_payload);

  CASE v_legacy

  -- ---- generic URN-addressed instance ops (the main goal) --------------
  WHEN 'instances.list', 'instances.last', 'instances.count', 'instance.get' THEN
    res := ckp._query(v_legacy, p_payload);

  -- ---- discovery -------------------------------------------------------
  WHEN 'affordances' THEN
    res := jsonb_build_object('ok', true, 'affordances', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', j->>'a', 'in', j->>'it', 'out', j->>'ot'))
      FROM pgrdf.sparql($q$ PREFIX ckp:<https://conceptkernel.org/ontology/v3.11/core#>
        SELECT ?a ?it ?ot WHERE { GRAPH ?g { ?a a ckp:Affordance .
          OPTIONAL { ?a ckp:inTopic ?it } OPTIONAL { ?a ckp:outTopic ?ot } } } ORDER BY ?a $q$) AS j
    ), '[]'::jsonb));

  WHEN 'kernels.list' THEN
    res := jsonb_build_object('ok', true, 'kernels', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', COALESCE(body->>RL, regexp_replace(id,'^backlog:','')),
        'id', id, 'urn', 'ckp://Kernel#'||ckp._slug(COALESCE(body->>RL, regexp_replace(id,'^backlog:','')))) ORDER BY id)
      FROM ckp.instances WHERE body->>'type' = N||'Goal' AND id LIKE 'backlog:%'), '[]'::jsonb));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1),
        'ledger', COALESCE((SELECT jsonb_agg(jsonb_build_object('seq',seq,'prev_seq',prev_seq,'body_sha256',body_sha256,'ts',ts) ORDER BY seq) FROM ckp.ledger WHERE instance_id=tid),'[]'::jsonb));
    END;

  WHEN 'instance.verify' THEN
    res := jsonb_build_object('ok', true, 'id', p_payload->>'id', 'verified', ckp.verify(p_payload->>'id'));

  -- ---- participant input (kernel governs by sealing) -------------------
  WHEN 'participant.join' THEN
    res := jsonb_build_object('ok', true, 'sub', p_payload->>'name',
      'urn', 'urn:ckp:participant:'||ckp._slug(p_payload->>'name'));

  WHEN 'kernel.create' THEN
    DECLARE nm text := p_payload->>'name'; gid text;
    BEGIN
      IF nm IS NULL OR btrim(nm)='' THEN res := jsonb_build_object('ok',false,'error','kernel name required');
      ELSE
        gid := 'backlog:'||nm;
        PERFORM ckp.seal(gid, jsonb_build_object('type', N||'Goal', '@id', 'ckp://Goal#'||gid, N||'goal_id', gid,
          RL, nm, N||'title', nm, N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        res := jsonb_build_object('ok',true,'kernel',nm,'id',gid);
      END IF;
    END;

  WHEN 'task.create' THEN
    DECLARE t jsonb := p_payload->'task'; k text := p_payload->'task'->>'target_kernel';
            -- F-A (pgCK#9/#10): identity is SERVER-DERIVED from the verified connection
            -- (the ckp.requester GUC the trusted ingress sets from the NATS-verified bearer),
            -- NEVER the client payload. A payload {sub} is ignored — it cannot forge created_by.
            sub text := current_setting('ckp.requester', true); tid text; qseq int; v_body jsonb;
    BEGIN
      IF k IS NULL OR (p_payload->'task'->>'title') IS NULL THEN
        res := jsonb_build_object('ok',false,'error','kernel and title required');
      ELSE
        SELECT COALESCE(MAX((i.body->>(N||'queue_seq'))::int),0)+1 INTO qseq
          FROM ckp.instances i WHERE i.body->>(N||'target_kernel')=k AND i.body->>'type'=N||'Task';
        tid := 'task-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        v_body := jsonb_build_object('type', N||'Task', '@id', 'ckp://Task#'||tid, N||'task_id', tid,
          N||'title', t->>'title', N||'part_of_goal', 'backlog:'||k, N||'target_kernel', k,
          N||'lifecycle_state', COALESCE(t->>'lifecycle_state','planned'),
          N||'priority', COALESCE(t->'priority','5'::jsonb), N||'queue_seq', to_jsonb(qseq),
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN
          v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub),
                                             'participant', jsonb_build_object('sub', sub));
        END IF;
        PERFORM ckp.seal(tid, v_body);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  WHEN 'task.update' THEN
    DECLARE tid text := p_payload->>'id'; cur jsonb; v_fld text;
    BEGIN
      SELECT body INTO cur FROM ckp.instances WHERE id=tid;
      IF cur IS NULL THEN res := jsonb_build_object('ok',false,'error','instance not found');
      ELSE
        cur := cur - 'participant';
        -- Apply EVERY patchable task field the caller sent (closed allow-list = the task
        -- model's mutable properties; never arbitrary keys), preserving JSON type with ->
        -- not ->> so a number stays a number end-to-end. Pre-0.4.3 this hardcoded only
        -- lifecycle_state + priority — it silently dropped title (CK.Lib.Js report 2.1) and
        -- ->> coerced priority 1 → "1" (report 2.2).
        FOREACH v_fld IN ARRAY ARRAY['title','priority','lifecycle_state','part_of_goal','target_kernel'] LOOP
          IF p_payload ? v_fld THEN
            cur := cur || jsonb_build_object(N||v_fld, p_payload->v_fld);
          END IF;
        END LOOP;
        PERFORM ckp.seal(tid, cur);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- board snapshot (web protocol verb the browser surfaces use) -------
  WHEN 'snapshot.board' THEN
    res := jsonb_build_object('ok', true,
      'kernels', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', i.body->>(N||'title'), 'id', i.id)
                    ORDER BY i.body->>(N||'title')), '[]'::jsonb)
                  FROM ckp.instances i WHERE i.body->>'type' = N||'Goal'),
      'tasks', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', i.id,
                  'title', i.body->>(N||'title'),
                  'target_kernel', i.body->>(N||'target_kernel'),
                  'part_of_goal', i.body->>(N||'part_of_goal'),
                  'lifecycle_state', i.body->>(N||'lifecycle_state'),
                  'priority', i.body->(N||'priority'),
                  'queue_seq', i.body->(N||'queue_seq'),
                  'created_by', i.body->>(N||'created_by'),
                  'proof_digest', (SELECT p.digest FROM ckp.proof p WHERE p.about = i.id ORDER BY p.id DESC LIMIT 1),
                  'verified', ckp.verify(i.id))
                  ORDER BY i.body->>(N||'target_kernel'), NULLIF(i.body->>(N||'queue_seq'),'')::int), '[]'::jsonb)
                FROM ckp.instances i WHERE i.body->>'type' = N||'Task'));

  -- ---- raw instance bodies — bulk replay for CKHexStore + corpus capture ---
  -- returns the literal IRI-keyed JSON-LD bodies (with @id + type), the shape a
  -- browser quad store ingests and a fixture corpus records (SPEC.CK.HEXSTORE Q4).
  WHEN 'snapshot.bodies' THEN
    DECLARE k text := p_payload->>'kernel';
    BEGIN
      res := jsonb_build_object('ok', true,
        'bodies', (SELECT coalesce(jsonb_agg(i.body ORDER BY i.id), '[]'::jsonb)
                   FROM ckp.instances i
                   WHERE k IS NULL OR i.body->>(N||'target_kernel') = k));
    END;

  -- ---- concept link (Edge) — captured so the structure is recoverable ---
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', N||'Edge', '@id', 'ckp://Edge#'||eid,
          N||'source', src, N||'predicate', pred, N||'target', tgt, N||'topic', topic,
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := COALESCE(p_payload->>'predicate','notifies');
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSE
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', N||'Message', '@id', 'ckp://Message#'||mid,
          N||'from', frm, N||'to', tgt, N||'predicate', pred, N||'body', bdy, N||'topic', topic,
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.project_links(p_project text, p_instance_id text, p_body jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
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
      '@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> . '
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
      '@prefix ckp:  <https://conceptkernel.org/ontology/v3.11/core#> . '
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
$function$
;

CREATE OR REPLACE FUNCTION ckp.propose_change(p_kernel_urn text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_core   int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_ops    text[] := ARRAY['add_class','add_property','modify_shape_constraint','add_affordance',
                           'set_transition_map','set_quorum','set_materialize_policy'];
  v_op     text := p_payload->>'op';
  v_about  text := COALESCE(p_payload->>'about', p_kernel_urn);
  v_quorum int;
  v_pid    text;
  v_body   jsonb;
  v_ttl    text;
  v_report jsonb;
BEGIN
  -- 1. INJECTION-SAFE FIELD GATE (mirrors ProposalShape; makes step 2's TTL construction safe).
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal_op', 'op', v_op,
                              'allowed', to_jsonb(v_ops));
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  BEGIN
    v_quorum := COALESCE((p_payload->>'requires_quorum')::int, 1);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum',
                              'value', p_payload->>'requires_quorum');
  END;
  IF v_quorum < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'value', v_quorum);
  END IF;

  v_pid := 'proposal-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 2. AUTHORITATIVE SHACL GATE — validate against ProposalShape (core graph). Values are
  --    field-validated above, so this string build cannot inject a triple.
  v_ttl := '@prefix ckp: <'||C||'> .'||chr(10)||
           '@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .'||chr(10)||
           '<ckp://Proposal#'||v_pid||'> a ckp:Proposal ; ckp:about <'||v_about||'> ; '||
           'ckp:proposalState "pending" ; ckp:requiresQuorum "'||v_quorum::text||'"^^xsd:integer ; '||
           'ckp:proposalOp "'||v_op||'" .';
  v_report := ckp.validate_report(v_ttl, v_core);
  IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'violations', v_report->'violations');
  END IF;

  -- 3. SEAL the Proposal{pending} — DATA about the type, not yet the type. ckp.seal writes the
  --    instance + ledger + proof HMAC chain.
  v_body := jsonb_build_object(
    'type',              C||'Proposal',
    '@id',               'ckp://Proposal#'||v_pid,
    C||'about',          v_about,
    C||'proposalState',  'pending',
    C||'proposalOp',     v_op,
    C||'requiresQuorum', v_quorum::text,
    'proposalDetail',    COALESCE(p_payload->'detail', '{}'::jsonb)
  );
  PERFORM ckp.seal(v_pid, v_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_pid, 'proposal_iri', 'ckp://Proposal#'||v_pid,
                            'state', 'pending', 'op', v_op, 'verified', ckp.verify(v_pid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.registry_refresh()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  r          record;
  v_kernel   text;
  v_verb     text;
  v_epoch    integer;
  v_delegate boolean;
  v_count    integer := 0;
BEGIN
  FOR r IN
    SELECT j->>'a'  AS iri,
           j->>'it' AS in_topic,
           j->>'ot' AS out_topic,
           j->>'is' AS in_shape,
           j->>'pl' AS plane,
           j->>'ep' AS epoch,
           j->>'dg' AS delegate
    FROM pgrdf.sparql($q$
      PREFIX ckp: <https://conceptkernel.org/ontology/v3.11/core#>
      SELECT ?a ?it ?ot ?is ?pl ?ep ?dg WHERE {
        GRAPH ?g {
          ?a a ckp:Affordance ; ckp:inTopic ?it .
          OPTIONAL { ?a ckp:outTopic ?ot }
          OPTIONAL { ?a ckp:inShape  ?is }
          OPTIONAL { ?a ckp:plane    ?pl }
          OPTIONAL { ?a ckp:epoch    ?ep }
          OPTIONAL { ?a ckp:delegate ?dg }
        } }
    $q$) AS j
  LOOP
    -- derive kernel + verb from inTopic: input.kernel.<Kernel>.action.<verb>
    v_kernel := substring(r.in_topic FROM '^input\.kernel\.([^.]+)\.action\.');
    v_verb   := regexp_replace(r.in_topic, '^input\.kernel\.[^.]+\.action\.', '');
    CONTINUE WHEN v_kernel IS NULL OR v_verb IS NULL OR v_verb = r.in_topic OR v_verb = '';

    -- typed-literal-safe parses (strip any ^^<datatype> suffix the engine may carry)
    v_epoch    := COALESCE(NULLIF(split_part(COALESCE(r.epoch,    ''), '^', 1), '')::integer, 1);
    v_delegate := COALESCE(NULLIF(split_part(COALESCE(r.delegate, ''), '^', 1), '')::boolean, false);

    INSERT INTO ckp.affordance_registry
      (kernel, verb, affordance_iri, in_topic, out_topic, in_shape, plane, epoch, delegate, refreshed_at)
    VALUES
      (v_kernel, v_verb, r.iri, r.in_topic, r.out_topic, r.in_shape,
       COALESCE(NULLIF(split_part(COALESCE(r.plane,''),'^',1),''), 'instance'),
       v_epoch, v_delegate, now())
    ON CONFLICT (kernel, verb) DO UPDATE SET
      affordance_iri = EXCLUDED.affordance_iri,
      in_topic   = EXCLUDED.in_topic,
      out_topic  = EXCLUDED.out_topic,
      in_shape   = EXCLUDED.in_shape,
      plane      = EXCLUDED.plane,
      epoch      = EXCLUDED.epoch,
      delegate   = EXCLUDED.delegate,
      refreshed_at = EXCLUDED.refreshed_at;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.seal(p_instance_id text, p_body jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_core   INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_kgraph INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
  v_identity_key TEXT := COALESCE(
    NULLIF(current_setting('ckp.identity_key', true), ''),
    (SELECT v FROM ckp.config WHERE k='identity_key')
  );
  v_project TEXT := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_type   TEXT := p_body->>'type';
  v_missing TEXT;
  v_sha    TEXT;
  v_sig    TEXT;
  v_prev   BIGINT;
  v_now    TIMESTAMPTZ := now();
  v_led_ttl TEXT;
  v_prf_ttl TEXT;
  v_sub    TEXT;
  v_display TEXT;
  v_email  TEXT;
  v_participant TEXT;
BEGIN
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'ckp.seal: body has no "type"';
  END IF;
  IF v_identity_key IS NULL OR v_identity_key = '' THEN
    RAISE EXCEPTION 'ckp.seal: no identity key configured';
  END IF;

  -- 0. RESOLVE participant identity (CKF-3). Map an optional "participant"
  -- claims object {sub, preferred_username, email} to the canonical IRI
  -- urn:ckp:participant:<normalised-sub>; mint urn:ckp:participant:anon:<nonce>
  -- when absent or sub is empty. Display claims (preferred_username, email)
  -- are carried as non-authoritative attributes per NOTIFIES.pgCK §D.
  -- This MUST run before the body SHA (step 2) so the stored body, the ledger
  -- digest, and ckp.verify()'s recompute all hash the same canonical body.
  v_sub     := p_body->'participant'->>'sub';
  v_display := NULLIF(trim(COALESCE(p_body->'participant'->>'preferred_username','')), '');
  v_email   := NULLIF(trim(COALESCE(p_body->'participant'->>'email','')), '');
  IF p_body ? 'participant' AND v_sub IS NOT NULL AND length(trim(v_sub)) > 0 THEN
    v_participant := 'urn:ckp:participant:' || ckp.urn_normalise(v_sub);
  ELSE
    v_participant := 'urn:ckp:participant:anon:' || gen_random_uuid()::text;
    v_display := NULL;
    v_email := NULL;
  END IF;
  -- Replace the raw claims object with the resolved canonical IRI; carry the
  -- display fields only when they were supplied alongside an identified sub.
  p_body := (p_body - 'participant')
    || jsonb_build_object(
      'https://conceptkernel.org/ontology/v3.11/core#participant', v_participant);
  IF v_display IS NOT NULL THEN
    p_body := jsonb_set(p_body, '{participant_display_name}', to_jsonb(v_display), true);
  END IF;
  IF v_email IS NOT NULL THEN
    p_body := jsonb_set(p_body, '{participant_email}', to_jsonb(v_email), true);
  END IF;

  -- 1. VALIDATE the payload against the COMPOSED shapes graph (P0-B, pgCK#25).
  --
  -- Was: a hand-rolled SPARQL scan for sh:minCount against the KERNEL graph only.
  -- That saw no core shape (the kernel graph holds only the kernel's own), and it
  -- read past every other SHACL component the engine enforces. Measured on the
  -- bench, same malformed body, two shapes graphs: kernel -> conforms TRUE,
  -- composed -> conforms FALSE. Twelve Core components are measured enforcing.
  --
  -- Now: project the body to RDF, stamp the declared type's ancestors so
  -- InstanceShape and friends target it (pgrdf.validate does NOT entail, and
  -- entailment is per-graph — either gap silently returns conforms=true), and
  -- validate against core UNION kernel.
  DECLARE
    v_comp    int;
    v_cand    text;
    v_report  jsonb;
  BEGIN
    v_comp := ckp._composed_shapes(v_project);
    -- pgCK#41: the four substrate-derived properties (producedBy, createdBy,
    -- sealedAtEpoch, conformsToShape) are demanded by ckp:InstanceShape with
    -- minCount 1, but were derived AFTER this gate — so on the v3.11 root every
    -- Instance-classed seal failed by construction. Derive them INTO the
    -- candidate the gate validates: what is checked is what will be stamped.
    v_cand := ckp._body_to_ttl(p_body, p_instance_id, v_comp)
              || ckp._parent_closure_ttl(v_type, p_instance_id, v_comp)
              || ckp._derived_stamp_ttl(p_instance_id, v_type, v_project, v_participant, v_comp);
    v_report := ckp.validate_report(v_cand, v_comp);
    IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'ckp.seal: payload fails the composed shape gate: %',
        COALESCE(ckp._report_summary(v_report), v_report::text);
    END IF;
  END;

  -- 2. MATERIALIZE durable instance.
  v_sha := encode(digest(convert_to(p_body::text,'UTF8'),'sha256'),'hex');
  v_sig := encode(hmac(v_sha, v_identity_key, 'sha256'),'hex');
  SELECT max(seq) INTO v_prev FROM ckp.ledger;
  INSERT INTO ckp.instances(id, body) VALUES (p_instance_id, p_body)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, ts_updated = v_now;

  -- 3. VALIDATE the protocol's OWN ledger op, then write it.
  v_led_ttl := format($t$
    @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:led:%s> a ckp:LedgerEntry ;
      ckp:about <%s> ; ckp:bodySha "%s" ; ckp:sig "%s" ;
      ckp:prev %s ;
      ckp:ts "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, v_sig,
    -- v3.11 LedgerEntryShape demands ckp:prev (minCount 1, xsd:integer) — the
    -- chain position, which v3.8 left implicit in the relational prev_seq.
    -- Genesis encodes as 0: the column stays NULL (no referent), the protocol
    -- statement is "nothing precedes me", and a bare Turtle integer is
    -- xsd:integer, matching the declared datatype.
    COALESCE(v_prev, 0)::text, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_led_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: ledger entry fails ckp:LedgerEntryShape (core governance)';
  END IF;
  INSERT INTO ckp.ledger(instance_id, body_sha256, sig, prev_seq)
  VALUES (p_instance_id, v_sha, v_sig, v_prev);

  -- 4. VALIDATE the protocol's OWN proof op, then write it.
  v_prf_ttl := format($t$
    @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:%s> a ckp:Proof ;
      ckp:about <%s> ; ckp:method "hmac+sha256" ; ckp:digest "%s" ;
      ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_prf_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: proof fails ckp:ProofShape (core governance)';
  END IF;
  INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id,'hmac+sha256',v_sha);

  -- 5. PROJECT link triples for Task/Goal instances into the project board graph (CKB-5).
  PERFORM ckp.project_links(v_project, p_instance_id, p_body);

  RETURN v_sha;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text DEFAULT 'demo'::text)
 RETURNS TABLE(shape_class text, target_class text, present boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_board_iri text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g   bigint := pgrdf.graph_id(v_board_iri);
  v_q         text;
  v_row       record;
  v_ask       text;
  v_missing   text[] := ARRAY[]::text[];
BEGIN
  IF v_board_g IS NULL THEN
    -- v0.4.2: no board ontology imported for this project — nothing loaded, nothing
    -- stale to guard. The gate arms itself when ckp.import_module() lands the shapes.
    RAISE NOTICE 'ckp.shapes_self_test: board graph % not imported yet — self-test skipped (valid silence; import task/goal modules to arm the board gate)', v_board_iri;
    RETURN;
  END IF;

  FOR v_row IN
    SELECT * FROM (VALUES
      ('ckp:TaskShape', 'ckp:Task'),
      ('ckp:GoalShape', 'ckp:Goal')
    ) AS expected(shape, target)
  LOOP
    v_q := format(
      'PREFIX ckp: <https://conceptkernel.org/ontology/v3.11/core#>
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
$function$
;

CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  N        text := 'https://conceptkernel.org/ontology/v3.7/';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
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

  -- T3 (v0.4.20, pgCK#7): does the instance's TYPE carry a sealed transition map in ANY kernel
  -- graph? Resolve project-independently — ckp:allowsTransition only exists in kernel graphs.
  v_has_map := (v_type IS NOT NULL AND v_type ~ '^[A-Za-z]' AND EXISTS (
    SELECT 1 FROM pgrdf.sparql(format($q$
      PREFIX ckp: <%s>
      SELECT ?t WHERE { GRAPH ?g { <%s> ckp:allowsTransition ?t } } LIMIT 1
    $q$, C, v_type)) j));

  IF v_has_map THEN
    -- the type's sealed map governs (wherever it lives). from must be a safe state to bind.
    v_src := 'kernel';
    IF v_from !~ v_state_re OR NOT EXISTS (
      SELECT 1 FROM pgrdf.sparql(format($q$
        PREFIX ckp: <%s>
        SELECT ?t WHERE { GRAPH ?g {
          <%s> ckp:allowsTransition ?t . ?t ckp:fromState "%s" ; ckp:toState "%s" } }
      $q$, C, v_type, v_from, v_to)) j) THEN
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
$function$
;

CREATE OR REPLACE FUNCTION ckp.validate(ttl text, shapes_graph_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  scratch_id INT := 1000000000 + pg_backend_pid();
  report jsonb;
BEGIN
  -- Bench-proven form (reconciled from pgck.localhost, 2026-08-08): the graph
  -- is materialized BEFORE validation. pgrdf.validate does not entail and
  -- entailment is per-graph, so without this the candidate's rdf:type closure
  -- is invisible to targetClass resolution and a malformed entry can conform
  -- vacuously — the PASS-10/PASS-17 failure shape, at the innermost gate.
  PERFORM pgrdf.add_graph(scratch_id, 'urn:ckp:scratch:'||scratch_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  PERFORM pgrdf.materialize(scratch_id);
  report := pgrdf.validate(scratch_id, shapes_graph_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.vote(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_core      int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_about     text := p_payload->>'about';   -- the Proposal @id (IRI)
  v_value     text := p_payload->>'value';   -- approve | reject
  v_prop      jsonb;
  v_quorum    int;
  v_approvals int;
  v_vid       text;
  v_body      jsonb;
  v_ttl       text;
  v_report    jsonb;
BEGIN
  -- 1. injection-safe field gate (mirrors VoteShape).
  IF v_value IS NULL OR v_value NOT IN ('approve','reject') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_vote_value', 'value', v_value);
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;

  -- 2. the Proposal must exist and still be pending.
  SELECT body INTO v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending',
                              'state', v_prop->>(C||'proposalState'));
  END IF;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);

  v_vid := 'vote-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 3. authoritative SHACL gate (VoteShape) — values field-validated, so the TTL is safe.
  v_ttl := '@prefix ckp: <'||C||'> .'||chr(10)||
           '<ckp://Vote#'||v_vid||'> a ckp:Vote ; ckp:about <'||v_about||'> ; '||
           'ckp:voteValue "'||v_value||'" .';
  v_report := ckp.validate_report(v_ttl, v_core);
  IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'violations', v_report->'violations');
  END IF;

  -- 4. seal the Vote (sealed by the session identity — a human approval is indistinguishable).
  v_body := jsonb_build_object(
    'type',         C||'Vote',
    '@id',          'ckp://Vote#'||v_vid,
    C||'about',     v_about,
    C||'voteValue', v_value
  );
  PERFORM ckp.seal(v_vid, v_body);

  -- 5. quorum check: COUNT approve-votes about this Proposal vs requiresQuorum.
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote'
      AND body->>(C||'about') = v_about
      AND body->>(C||'voteValue') = 'approve';

  RETURN jsonb_build_object('ok', true, 'vote', v_vid, 'proposal', v_about, 'value', v_value,
                            'approvals', v_approvals, 'quorum', v_quorum,
                            'quorum_met', v_approvals >= v_quorum, 'verified', ckp.verify(v_vid));
END;
$function$
;

-- ckp.boot — carries the fresh-install ring repair (see the body): boot's
-- dynamically created pgrdf graph tables must be readable by the ck_substrate
-- definer ring, and the completeness floor ran before they existed.
CREATE OR REPLACE PROCEDURE ckp.boot(IN p_core_ttl_path text DEFAULT '/ontology/core.ttl'::text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE v_core INT; v_ttl TEXT; v_shapes INT;
BEGIN
  PERFORM pgrdf.shmem_reset();
  -- P0-A0 (pgCK#23): resolve the core graph BY IRI and record the id it got.
  -- Never assume an id from config. Two paths bound graphs — one by explicit
  -- id from ckp.config, one by IRI with an auto-assigned id — and whichever ran
  -- first won the id. That left core_graph_id pointing at the kernel graph and
  -- boot raising 'graph_id 1 is bound to a different IRI' on every run, so the
  -- core ontology was never loaded and every ckp.validate(_, core) conformed
  -- trivially against an empty shapes graph.
  v_core := pgrdf.add_graph('urn:ckp:core');
  INSERT INTO ckp.config(k,v) VALUES ('core_graph_id', v_core::text)
    ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
  -- Fail loudly. An empty core graph is not a runnable state: it makes the
  -- seal's own ledger/proof gate unreachable and every core constraint inert.
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF v_shapes = 0 THEN
    RAISE EXCEPTION 'ckp.boot: core ontology at % loaded 0 sh:NodeShape — refusing to run with an unenforced core', p_core_ttl_path;
  END IF;
  -- Ring repair (fresh install, measured 2026-08-08): the per-graph tables
  -- this boot just created belong to the CALLING superuser — boot cannot be a
  -- ck_substrate definer because pg_read_file is superuser-gated — while every
  -- internal that reads them (ckp._composed_shapes and the rest of the ring-1
  -- definer set) runs as ck_substrate. On a fresh install the completeness
  -- floor ran at CREATE EXTENSION, before these tables existed, so the first
  -- seal died inside pgrdf.copy_graph with `permission denied for table
  -- _pgrdf_quads_g1`. Re-assert the substrate floor over pgrdf exactly as the
  -- completeness pass states it, now covering the dynamically created tables.
  -- (The lasting fix is a grant at creation inside pgrdf.add_graph — filed
  -- against pgRDF; this covers every graph boot itself creates.)
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
  RAISE NOTICE 'ckp.boot: core graph % loaded from %, % NodeShapes', v_core, p_core_ttl_path, v_shapes;
END;
$procedure$
;

-- ckp._enforce_internal_floor — now also grants schema USAGE to ck_substrate
-- and ck_drainer (fresh-install ring repair; a no-op where already granted).
CREATE OR REPLACE PROCEDURE ckp._enforce_internal_floor()
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
BEGIN
  -- Single idempotent statement set: applies to EVERY table/sequence currently in
  -- schema ckp (config + dictionary now; instances/ledger/proof/outbox after
  -- bootstrap; plans after CI-C-4). No PUBLIC; ck_substrate is the operating role.
  REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM PUBLIC;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM PUBLIC;
  GRANT  ALL ON ALL TABLES    IN SCHEMA ckp TO ck_substrate;
  GRANT  ALL ON ALL SEQUENCES IN SCHEMA ckp TO ck_substrate;
  -- Schema USAGE for the operating roles (measured missing from zero,
  -- 2026-08-08): the ring-1 definer set runs as ck_substrate and resolves
  -- ckp.* by name, and the outbox drain connects as ck_drainer — without
  -- USAGE both die on a FRESH install ('permission denied for schema ckp')
  -- while every long-lived bench works, because its grants predate the
  -- completeness file. The completeness pass grants ckp USAGE to
  -- ck_participant only; these two were only ever granted by hand.
  GRANT  USAGE ON SCHEMA ckp TO ck_substrate;
  GRANT  USAGE ON SCHEMA ckp TO ck_drainer;
END;
$procedure$
;

-- Run it: an upgraded database gets the corrected floor immediately, not at
-- its next bootstrap.
CALL ckp._enforce_internal_floor();

-- ── Ring-1 re-assert ─────────────────────────────────────────────────────────
-- Measured on the upgrade path: CREATE OR REPLACE resets SECURITY DEFINER and
-- ownership to whatever the statement text says, and the completeness pass
-- that hardens the whole schema runs only at CREATE EXTENSION. Without this,
-- every function this script replaced (and the new stamp helper) executed
-- with caller rights on upgraded databases while fresh installs were
-- hardened — same extversion, different ring. Re-run the completeness pass's
-- own loop, verbatim: functions SECURITY DEFINER + ck_substrate + pinned
-- search_path; procedures owned + pinned, SECURITY INVOKER (boot/import use
-- pg_read_file, which needs the caller's superuser rights).
DO $floor_0428$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT pr.oid, pr.prokind
    FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.prokind IN ('f','p')
  LOOP
    IF p.prokind = 'f' THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    ELSE
      EXECUTE format('ALTER PROCEDURE %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER PROCEDURE %s SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    END IF;
  END LOOP;
END
$floor_0428$;

-- The participant floor for the new helper (the loop above owns and hardens;
-- it does not touch ACLs):
REVOKE ALL ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) TO ck_substrate;

-- And the table/sequence/schema floor, which also covers the schema-USAGE
-- repair for ck_substrate and ck_drainer on upgraded databases:
CALL ckp._enforce_internal_floor();
