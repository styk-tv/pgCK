-- pgck 0.4.36 -> 0.4.37 — B4 (pgCK's half): the enforcement surface is CHECKED
-- against the digests its own epoch sealed, and the check is a declared verb.
--
-- WHY. urn:ckp:pgCK/kernel/ck was wiped to zero triples by a concurrent writer
-- on 2026-08-10, between one seal and the next. Nothing raised. _composed_shapes
-- happily rebuilt the surface WITHOUT the kernel's shapes — silently narrower,
-- still "conforming" — and it was found only because a query returned 0 rows by
-- luck. That is the defect class this whole line exists to end: not a wrong
-- answer, an unnoticed one.
--
-- WHAT pgCK CAN AND CANNOT DO. Preventing the wipe is graph LIFECYCLE, which
-- lives in the engine layer (pgRDF 0.6.25 enforces import -> materialize ->
-- validate -> checkpoint and refuses to validate an `untracked` graph; pgCK's
-- graphs are all untracked, and the lock primitive is not in pgrdf's SQL
-- surface). So prevention is a coordination ask, filed, not faked here.
-- DETECTION is entirely pgCK's, and detection is what was missing.
--
-- THE TRIPWIRE ALREADY EXISTED — 0.4.31 just never read it back. Every governed
-- apply seals a ckp:Materialization carrying sourceDigest (the KERNEL graph) and
-- surfaceDigest (the COMPOSED enforcement surface), and a ckp:Epoch carrying the
-- same surfaceDigest. So the substrate has, on the ledger, a signed statement of
-- what its surface looked like at the epoch in force. Comparing the live digests
-- against those is P12/I14 made operational: *the surface in force is established
-- by digest*, not assumed to still be what it was.
--
-- REPORTS, NEVER REFUSES. ckp.surface_check is a READ. It does not gate the seal,
-- deliberately: a false positive here would take the whole substrate down, and
-- legitimate drift exists (adopting a module changes the composed surface without
-- advancing the epoch — visible in the very first run of this check). A gate that
-- can be wrong about the surface is worse than a report that is always right about
-- what it measured. Findings are named; an empty findings list is the only pass.
--
-- DECLARED, NOT JUST DISPATCHABLE. The verb is added to the door AND intended to
-- be sealed as a ckp:Affordance with a derivedBy — so it does not grow the
-- 1-declared/21-unsealed gap B1 measured. It is the first verb that is both
-- dispatchable and declared, which is the shape #56 has to end in.

CREATE OR REPLACE FUNCTION ckp.surface_check(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj   text := COALESCE(p_project, NULLIF(current_setting('ckp.project', true), ''), 'demo');
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

REVOKE ALL ON FUNCTION ckp.surface_check(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp.surface_check(text) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp.surface_check(text) TO ck_substrate;

-- The door, carrying the new verb. Spelled identically to the baseline (rule 3).
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
  -- B4: the surface in force, checked against the digests its epoch sealed.
  -- A READ, never a gate — a false positive here would take the substrate down,
  -- and legitimate drift exists. Findings name what was measured; empty = pass.
  WHEN 'surface.check' THEN
    res := ckp.surface_check(v_proj);

  WHEN 'affordances' THEN
    -- B1 (pgCK#56): derived from SEALED ckp:Affordance instances of THIS kernel,
    -- carrying inShape resolved into a real input contract, retirement honoured,
    -- and the registry/sealed drift reported under `unsealed` rather than merged.
    -- Was: an unfiltered SPARQL scan of a graph nobody writes, which returned []
    -- for a substrate holding sealed affordances — reads as "no grants", means
    -- "nothing declared".
    res := ckp.affordances_of(v_proj);

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

-- Register the built-in on the upgrade route too (the seed block only runs at install).
INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane)
VALUES ('pgCK','surface.check','input.kernel.pgCK.action.surface.check','instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'instance', refreshed_at = now();

CALL ckp._enforce_internal_floor();
