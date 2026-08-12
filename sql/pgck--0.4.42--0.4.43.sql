-- pgck 0.4.43 — ckp.germinate_kernel: creating a concept kernel becomes a GOVERNED act
--
-- THE HOLE THIS FILLS. pgCK shipped `kernel.create`, which sealed a v3.7 Goal at
-- backlog:<name> — no graph, no organs, no ckp:Kernel, no validation. So the only
-- working route to a new kernel was pgRDF's import/materialize/validate/checkpoint,
-- which has NO IDENTITY COLUMN: the structure lands correctly and belongs to nobody.
-- Every kernel in the fleet was made that way. That is not a workflow, it is a hole
-- where the core function should be.
--
-- WHAT A CLIENT MAY AND MAY NOT DO (pgCK.MCP's correction, adopted):
--   a client MAY declare its own STRUCTURE   — Kernel + three organs
--   a client MAY NOT declare WHO OWNS IT     — ProjectShape requires ckp:ownedBy,
--                                              and inventing an owner is a forgery
-- Those two were conflated into "a client cannot germinate at all", which would have
-- left every workspace unable to create a kernel on a wrong inference. The narrow,
-- correct line is the one above — and the substrate can cross it, because it already
-- derives identity from the verified connection for ckp:createdBy. ownedBy is stamped
-- the SAME WAY, from ckp.requester, never from the payload.
--
-- MEASURED SHAPES (against the loaded root e5f7d1e5):
--   KernelShape   label 1 · epoch 1 · hasOrgan minCount 3 IRI · inProject 1 IRI
--   ProjectShape  label 1 · projectKind 1 in(personal|shared) · ownedBy 1 IRI
--   CK organ      organKind hasValue "ck"   · writeAuthority hasValue "governed-only"
--                 · dependsOn maxCount 0
--   TOOL/DATA     counted dependsOn 1 and 2 (the Separation Axiom, sh:hasValue-gated)

CREATE OR REPLACE FUNCTION ckp.germinate_kernel(p_project text, p_label text DEFAULT NULL,
                                                p_kind text DEFAULT 'personal')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub   text := NULLIF(current_setting('ckp.requester', true), '');
  v_owner text;
  v_label text := COALESCE(p_label, p_project);
  v_iri   text := format('urn:ckp:%s/kernel/ck', p_project);
  v_g     int;
  v_ttl   text;
  v_base  text := format('urn:ckp:%s', p_project);
  v_kid   text := format('urn:ckp:%s/kernel', p_project);
  v_pid   text := format('urn:ckp:project:%s', p_project);
BEGIN
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'project required');
  END IF;
  -- The transport segment is one NATS token. A dotted name can never be granted
  -- (configured_kernels drops it), so germinating one would build a kernel nobody
  -- can ever reach. Refuse at the door with the slug it should use.
  IF p_project ~ '[.*> \t\r\n]' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', format('kernel id %L carries a NATS subject metacharacter, so it can never be granted. Use %L.',
                      p_project, ckp._slug(p_project)));
  END IF;
  -- IDENTITY IS SERVER-DERIVED. No verified connection, no owner, no germination —
  -- fail closed rather than mint an unowned project or invent an owner.
  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', 'germination requires a verified identity: ckp.ownedBy is stamped from the connection, never supplied. Anonymous callers cannot own a project.');
  END IF;
  v_owner := 'urn:ckp:participant:' || ckp._slug(v_sub);

  -- 1. the structure — Kernel + three organs, counted dependencies, gated authorities
  v_g := pgrdf.add_graph(v_iri);
  PERFORM pgrdf.clear_graph(v_g);
  v_ttl := format($ttl$
@prefix ckp:  <https://conceptkernel.org/ontology/v3.11/core#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
<%1$s/kernel> a ckp:Kernel ; rdfs:label %2$L ; ckp:epoch 0 ;
  ckp:inProject <%3$s> ;
  ckp:hasOrgan <%1$s/organ/ck> , <%1$s/organ/tool> , <%1$s/organ/data> .
<%1$s/organ/ck>   a ckp:Organ , ckp:CK   ; ckp:organKind "ck"   ; ckp:writeAuthority "governed-only" .
<%1$s/organ/tool> a ckp:Organ , ckp:TOOL ; ckp:organKind "tool" ; ckp:writeAuthority "readonly-on-ontology" ;
  ckp:dependsOn <%1$s/organ/ck> .
<%1$s/organ/data> a ckp:Organ , ckp:DATA ; ckp:organKind "data" ; ckp:writeAuthority "readwrite" ;
  ckp:dependsOn <%1$s/organ/ck> , <%1$s/organ/tool> .
$ttl$, v_base, v_label, v_pid);
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, v_iri || '#');
  PERFORM pgrdf.materialize(v_g);
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;

  -- 2. the Project — ownedBy STAMPED, never supplied. This is the triple a client
  --    cannot write and the reason germination is a governed verb at all.
  PERFORM ckp.seal(v_pid, jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Project',
    '@id',  v_pid,
    'http://www.w3.org/2000/01/rdf-schema#label', v_label,
    'https://conceptkernel.org/ontology/v3.11/core#projectKind', p_kind,
    'https://conceptkernel.org/ontology/v3.11/core#ownedBy', v_owner));

  -- 3. the Kernel as a SEALED, ATTRIBUTED fact — so the kernel exists in the ledger
  --    and not only as quads a stranger could have written.
  PERFORM ckp.seal(v_kid, jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Kernel',
    '@id',  v_kid,
    'http://www.w3.org/2000/01/rdf-schema#label', v_label,
    'https://conceptkernel.org/ontology/v3.11/core#epoch', 0,
    'https://conceptkernel.org/ontology/v3.11/core#inProject', v_pid,
    'https://conceptkernel.org/ontology/v3.11/core#hasOrgan',
      -- The organs live at <base>/organ/*, NOT <base>/kernel/organ/*. Both the
      -- graph above and pgCK's own kernel use the former; deriving these from
      -- v_kid (which already ends in /kernel) sealed a Kernel whose hasOrgan
      -- pointed at three resources that do not exist. KernelShape only counts
      -- them and checks nodeKind, so the gate passed and the drift was silent.
      jsonb_build_array(v_base||'/organ/ck', v_base||'/organ/tool', v_base||'/organ/data')));

  RETURN jsonb_build_object('ok', true, 'kernel', v_kid, 'graph', v_iri,
                            'project', v_pid, 'ownedBy', v_owner, 'organs', 3);
END;
$function$;

COMMENT ON FUNCTION ckp.germinate_kernel(text, text, text) IS
  'Governed germination. A client declares its STRUCTURE (Kernel + three organs); the '
  'substrate stamps WHO OWNS IT (ckp:ownedBy) from the verified connection, exactly as '
  'ckp:createdBy is derived — never from the payload. Refuses anonymously, and refuses a '
  'kernel id carrying a NATS subject metacharacter because such a kernel could never be '
  'granted. Replaces the pgRDF route, which lands correct structure that belongs to nobody.';

-- ckp.dispatch — routes the new kernel.germinate verb (two-route parity)
CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
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

  -- B3: the store-level G-1 audit — the cross-node integrity body locality puts
  -- beyond the instance gate (§4.5). B1a: authority resolved by traversal, with
  -- an empty chain reported AS empty (persona spec §3).
  WHEN 'integrity.check' THEN
    res := ckp.integrity_check(v_proj);

  WHEN 'authority.mine' THEN
    res := ckp.authority_of(NULL);

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

  -- 0.4.43: germination as a GOVERNED act. kernel.create seals a board Goal and
  -- creates no kernel; the pgRDF route creates a correct kernel that belongs to
  -- nobody. This is the one that does both: client declares structure, substrate
  -- stamps ckp:ownedBy from the verified connection.
  WHEN 'kernel.germinate' THEN
    res := ckp.germinate_kernel(
             COALESCE(p_payload->>'project', p_payload->>'name'),
             p_payload->>'label',
             COALESCE(p_payload->>'projectKind', 'personal'));

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
$function$;

-- ckp._body_to_ttl — arrays expand into one triple per element (multi-valued
-- properties were silently dropped, making ckp:Kernel unsealable)
CREATE OR REPLACE FUNCTION ckp._body_to_ttl(p_body jsonb, p_subj text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type text := p_body->>'type';
  v_ttl  text;
  v_key  text;
  v_val  jsonb;
  v_obj  text;
  s      text;
BEGIN
  v_ttl := '<'||p_subj||'> a <'||COALESCE(v_type, 'urn:ckp:Unknown')||'> .'||chr(10);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_body)
  LOOP
    -- control keys + non-IRI keys are not RDF properties.
    CONTINUE WHEN v_key IN ('type','@id','participant','participant_display_name','participant_email');
    CONTINUE WHEN position(':' in v_key) = 0;
    IF    jsonb_typeof(v_val) = 'number'  THEN v_obj := v_val::text;            -- xsd:integer / decimal
    ELSIF jsonb_typeof(v_val) = 'boolean' THEN v_obj := v_val::text;            -- xsd:boolean
    ELSIF jsonb_typeof(v_val) = 'string'  THEN
      s := v_val #>> '{}';
      IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' THEN
        v_obj := '<'||s||'>';                                                   -- IRI node (nodeKind sh:IRI)
      ELSE
        v_obj := '"'||replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'"';  -- xsd:string literal
      END IF;
    ELSIF jsonb_typeof(v_val) = 'array' THEN
      -- 0.4.43: ARRAYS EXPAND INTO ONE TRIPLE PER ELEMENT. They were silently
      -- dropped here, so NO sealed instance could carry a multi-valued property —
      -- which made ckp:Kernel unsealable, because KernelShape requires
      -- hasOrgan minCount 3. That is the whole reason "pgCK cannot create a concept
      -- kernel" was true: not a design decision, a serializer gap. Measured:
      -- germinate refused with MinCount(3) not satisfied while the body carried all
      -- three organs. Same value rules as the scalar arm, per element.
      FOR s IN SELECT jsonb_array_elements_text(v_val) LOOP
        IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' THEN
          v_ttl := v_ttl||'<'||p_subj||'> <'||v_key||'> <'||s||'> .'||chr(10);
        ELSE
          v_ttl := v_ttl||'<'||p_subj||'> <'||v_key||'> "'||
                   replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'" .'||chr(10);
        END IF;
      END LOOP;
      CONTINUE;
    ELSE
      CONTINUE;                                                                 -- objects: not simple values
    END IF;
    v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> '||v_obj||' .'||chr(10);
  END LOOP;
  RETURN v_ttl;
END;
$function$;

-- ---------------------------------------------------------------------------
-- D2: ckp.validate must not aim its scratch graph at live data.
--
-- The scratch graph id was computed as 1000000000 + pg_backend_pid(). pgrdf
-- allocates data graphs from that same band, so the two collide on ordinary
-- container pids. Measured on the bench: 59 live graphs at offsets 112..1637,
-- and the CORE ontology at 1000000221 -- i.e. a backend with pid 221.
--
-- A backend that drew a colliding pid ran clear_graph against a real graph.
-- pgrdf refused with "graph_id ... is bound to a different IRI", so the data
-- survived, but ckp.validate then raised -- and because every seal validates,
-- EVERY write from that backend failed with a governance error that had
-- nothing to do with the payload. Intermittent, pid-dependent, unreproducible.
--
-- add_graph(iri) allocates outside the data band, is idempotent, and returns
-- the id; the scratch is one-per-backend and cannot alias a data graph.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp.validate(ttl text, shapes_graph_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  scratch_id BIGINT := pgrdf.add_graph('urn:ckp:validate-scratch:'||pg_backend_pid());
  report jsonb;
BEGIN
  -- The graph is materialized BEFORE validation: pgrdf.validate does not
  -- entail and entailment is per-graph, so without this the candidate's
  -- rdf:type closure is invisible to targetClass resolution and a malformed
  -- entry conforms vacuously (the PASS-10/PASS-17 failure shape).
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  PERFORM pgrdf.materialize(scratch_id);
  report := pgrdf.validate(scratch_id, shapes_graph_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$function$;

-- ---------------------------------------------------------------------------
-- The 3-arg overload is the one ckp.seal calls. It had the same array gap as
-- its 2-arg sibling above, so fixing only that one changed nothing: germinate
-- still refused ckp:Kernel with hasOrgan MinCount(3) while the body carried
-- all three organs. Overload parity is a route, like baseline/upgrade parity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp._body_to_ttl(p_body jsonb, p_subj text, p_shapes_graph integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type text := p_body->>'type';
  v_ttl text; v_key text; v_val jsonb; v_obj text; s text;
  v_dt jsonb := '{}'::jsonb; j jsonb; v_giri text; v_d text;
BEGIN
  IF p_shapes_graph IS NOT NULL THEN
    SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_shapes_graph;
    FOR j IN SELECT * FROM pgrdf.sparql(format($q$
        PREFIX sh: <http://www.w3.org/ns/shacl#>
        SELECT ?path ?dt WHERE { GRAPH <%s> { ?s sh:property ?p . ?p sh:path ?path ; sh:datatype ?dt } }
      $q$, v_giri))
    LOOP
      v_dt := v_dt || jsonb_build_object(j->>'path', j->>'dt');
    END LOOP;
  END IF;

  v_ttl := '<'||p_subj||'> a <'||COALESCE(v_type,'urn:ckp:Unknown')||'> .'||chr(10);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_body)
  LOOP
    CONTINUE WHEN v_key IN ('type','@id','participant','participant_display_name','participant_email');
    CONTINUE WHEN position(':' in v_key) = 0;
    v_d := v_dt->>v_key;
    IF    jsonb_typeof(v_val) = 'number'  THEN v_obj := v_val::text;
    ELSIF jsonb_typeof(v_val) = 'boolean' THEN v_obj := v_val::text;
    ELSIF jsonb_typeof(v_val) = 'string'  THEN
      s := v_val #>> '{}';
      IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' AND (v_d IS NULL OR v_d = '') THEN
        v_obj := '<'||s||'>';
      ELSE
        v_obj := '"'||replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'"';
        -- declared datatype wins; xsd:string is the default and needs no tag
        IF v_d IS NOT NULL AND v_d <> 'http://www.w3.org/2001/XMLSchema#string' THEN
          v_obj := v_obj||'^^<'||v_d||'>';
        END IF;
      END IF;
    ELSIF jsonb_typeof(v_val) = 'array' THEN
      -- A multi-valued property emits one triple per element. Without this arm
      -- arrays were silently dropped, so no sealed instance could carry a
      -- repeated property -- which made ckp:Kernel unsealable, since it
      -- requires three organs: germinate refused with hasOrgan MinCount(3)
      -- while the body carried all three. Same value rules as the scalar arm,
      -- applied per element. NOTE this is the 3-arg overload, the one ckp.seal
      -- actually calls; fixing only the 2-arg sibling changes nothing.
      FOR s IN SELECT jsonb_array_elements_text(v_val) LOOP
        IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' AND (v_d IS NULL OR v_d = '') THEN
          v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> <'||s||'> .'||chr(10);
        ELSE
          v_obj := '"'||replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'"';
          IF v_d IS NOT NULL AND v_d <> 'http://www.w3.org/2001/XMLSchema#string' THEN
            v_obj := v_obj||'^^<'||v_d||'>';
          END IF;
          v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> '||v_obj||' .'||chr(10);
        END IF;
      END LOOP;
      CONTINUE;
    ELSE CONTINUE;
    END IF;
    v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> '||v_obj||' .'||chr(10);
  END LOOP;
  RETURN v_ttl;
END;
$function$
;
