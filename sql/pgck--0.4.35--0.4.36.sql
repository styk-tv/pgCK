-- pgck 0.4.35 -> 0.4.36 — B1: the affordance projection is derived from SEALED
-- facts, carries inShape as a real schema, filters by kernel, honours retirement
-- — and reports the registry/sealed drift instead of hiding it (pgCK#56).
--
-- WHAT WAS WRONG. `affordances` answered from a SPARQL scan for `?a a
-- ckp:Affordance` across every graph: no kernel filter, no retirement check, no
-- inShape, and — most importantly — reading a graph nobody writes, while
-- dispatch resolved from the relational ckp.affordance_registry and the governed
-- truth sat in sealed ckp.instances. THREE stores, not two. `[]` was therefore
-- the honest answer for a substrate with sealed affordances, which reads exactly
-- like "no grants" and means "nothing declared" (a FalseGate, named by pgCK.MCP).
--
-- WHAT THE ROOT ALREADY DECIDES. ckp:AffordanceShape gates inTopic (minCount 1),
-- plane (sh:in instance|governance|derived), retiredAtEpoch, delegate, and
-- derivedBy (minCount 1 — every conformant affordance names the Materialization
-- that produced it). So the projection invents nothing: it reads the fields the
-- gate already enforces off the instances the seal already stamped.
--
-- inShape IS A SCHEMA, NOT A NAME. ckp:inShape points at a sh:NodeShape, and the
-- composed graph carries that shape's full constraint set. ckp._affordance_schema
-- resolves it into paths + datatype + cardinality + nodeKind + pattern + enum —
-- so a client derives a real input contract rather than a bare IRI. This is what
-- lets a conformant TOOL organ hold no schema of its own: it reads its output
-- contract from the kernel definition, and an applied change advances the
-- contract with zero tool-code edits (root, ckp:TOOL).
--
-- G-1, HONESTLY. Body locality forbids the instance gate requiring inShape or
-- derivedBy to RESOLVE (measured: an Affordance naming a non-existent
-- Materialization seals). So the projection reports what it found rather than
-- asserting: an unresolvable inShape yields schema:null with schema_resolved
-- false, never an invented contract. Absence is stated, not filled in.
--
-- DRIFT IS REPORTED, NOT UNIONED. A registry row with no sealed Affordance is
-- exactly the "hand-registered action" derivedBy's comment says cannot hide —
-- and it can, today, because the registry is written by apply directly. Merging
-- the two stores would make the drift invisible; the projection returns it under
-- `unsealed` so dispatchable-but-undeclared is VISIBLE and countable. Closing
-- the split by construction is pgCK#56 proper; this makes it measurable first.

-- ---------------------------------------------------------------------------
-- The input contract behind an inShape, resolved from the composed surface.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp._affordance_schema(p_shape_iri text, p_comp integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_giri text;
  v_props jsonb;
BEGIN
  IF p_shape_iri IS NULL OR p_comp IS NULL THEN RETURN NULL; END IF;
  SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_comp;
  IF v_giri IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'path',     j->>'path',
           'name',     regexp_replace(j->>'path', '^.*[#/]', ''),
           'datatype', j->>'dt',
           'required', CASE WHEN COALESCE((j->>'mn')::int, 0) >= 1 THEN true ELSE NULL END,
           'maxCount', (j->>'mx')::int,
           'nodeKind', regexp_replace(COALESCE(j->>'nk',''), '^.*[#/]', ''),
           'pattern',  j->>'pat'
         )) ORDER BY j->>'path')
    INTO v_props
  FROM pgrdf.sparql(format($q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?path ?dt ?mn ?mx ?nk ?pat WHERE { GRAPH <%s> {
      <%s> sh:property ?p . ?p sh:path ?path .
      OPTIONAL { ?p sh:datatype ?dt } OPTIONAL { ?p sh:minCount ?mn }
      OPTIONAL { ?p sh:maxCount ?mx } OPTIONAL { ?p sh:nodeKind ?nk }
      OPTIONAL { ?p sh:pattern ?pat } } }$q$, v_giri, p_shape_iri)) j;

  -- Unresolvable => NULL, never an empty contract. A shape that resolves to
  -- nothing and a shape that is not there must not read the same.
  IF v_props IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('shape', p_shape_iri, 'properties', v_props);
END;
$function$
;

-- ---------------------------------------------------------------------------
-- The projection: sealed affordances of ONE kernel, live at the current epoch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp.affordances_of(p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N       text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_kern  text := 'urn:ckp:'||p_project||'/kernel/ck';
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = p_project), 0);
  v_comp  int;
  v_list  jsonb;
  v_unsealed jsonb;
BEGIN
  v_comp := ckp._composed_shapes(p_project);

  SELECT jsonb_agg(a ORDER BY a->>'name') INTO v_list FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'name',    regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', ''),
      'iri',     i.body->>'@id',
      'in',      i.body->>(N||'inTopic'),
      'out',     i.body->>(N||'outTopic'),
      'plane',   i.body->>(N||'plane'),
      'delegate', (i.body->>(N||'delegate'))::boolean,
      'inShape', i.body->>(N||'inShape'),
      -- inShape resolved into a real input contract, or null + a marker. §4.5:
      -- report what was found; never invent a contract for a dangling IRI.
      'schema',  ckp._affordance_schema(i.body->>(N||'inShape'), v_comp),
      'schema_resolved',
                 CASE WHEN i.body ? (N||'inShape')
                      THEN ckp._affordance_schema(i.body->>(N||'inShape'), v_comp) IS NOT NULL
                      ELSE NULL END,
      -- provenance for the affordance ITSELF (root: derivedBy minCount 1)
      'derivedBy', i.body->>(N||'derivedBy'),
      'sealedAtEpoch', (i.body->>(N||'sealedAtEpoch'))::int
    )) AS a
    FROM ckp.instances i
    WHERE i.body->>'type' = N||'Affordance'
      -- kernel filter: producedBy is the substrate-stamped kernel, unforgeable
      AND i.body->>(N||'producedBy') = v_kern
      -- retirement honoured: retired AT or BEFORE the current epoch is gone
      AND (NOT (i.body ? (N||'retiredAtEpoch'))
           OR (i.body->>(N||'retiredAtEpoch'))::int > v_epoch)
  ) s;

  -- The #56 split, made VISIBLE: verbs dispatch resolves that no sealed
  -- Affordance declares. Reported, never merged — a union would hide exactly
  -- the hand-registered action the root says cannot hide.
  SELECT jsonb_agg(r.verb ORDER BY r.verb) INTO v_unsealed
  FROM ckp.affordance_registry r
  WHERE r.kernel = p_project
    AND NOT EXISTS (
      SELECT 1 FROM ckp.instances i
      WHERE i.body->>'type' = N||'Affordance'
        AND i.body->>(N||'producedBy') = v_kern
        AND regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', '') = r.verb);

  RETURN jsonb_build_object(
    'ok', true,
    'kernel', p_project,
    'epoch', v_epoch,
    'affordances', COALESCE(v_list, '[]'::jsonb),
    'unsealed', COALESCE(v_unsealed, '[]'::jsonb));
END;
$function$
;

REVOKE ALL ON FUNCTION ckp._affordance_schema(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._affordance_schema(text,integer) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._affordance_schema(text,integer) TO ck_substrate;
REVOKE ALL ON FUNCTION ckp.affordances_of(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp.affordances_of(text) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp.affordances_of(text) TO ck_substrate;

-- The dispatch door, rewired to the projection. Spelled identically to the
-- baseline (rule 3: a database reached by CREATE EXTENSION and one reached by
-- ALTER EXTENSION UPDATE must carry the same catalog, not just the same version).
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

CALL ckp._enforce_internal_floor();
