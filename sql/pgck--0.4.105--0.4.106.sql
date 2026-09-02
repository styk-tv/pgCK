-- pgck 0.4.105 -> 0.4.106
--
-- C-15 · every refusal carries a registered code and sqlstate; an ok:false
--        with neither is fault-shaped.
--
-- The sweep, measured before it ran: 89 of 97 refusal construction sites
-- carried no sqlstate — refusals a classifier cannot key on, exactly the
-- untyped prose B7/L-7 scheduled for its own release. Now every site types
-- itself, one of three ways:
--   * a LITERAL refusal code carries the sqlstate its registry row declares
--     (79 sites, mapped mechanically FROM ckp.refusal_registry — one source
--     of truth, never a second hand-spelled copy);
--   * a FAULT wrapper ('error', SQLERRM) carries the REAL SQLSTATE of the
--     exception it caught — a fault stays fault-shaped, and pgRDF's rule
--     ("treat anything not class XX as a refusal") becomes evaluable;
--   * the delegate seam types as 0A000 — not refused-by-law but
--     not-served-at-THIS-tier; the germinate guards as 22023/42501.
-- Eight codes the registry never carried are registered in the same act
-- (apply-stage projector wrappers 55000, delegate seam 0A000, kernel
-- resolution 42704) — a code returned but not registered teaches nothing.
--
-- Controls: s86 (wired into smoke-s4) — zero untyped sites measured from the
-- live catalog, every returned literal code registered, and a live refusal's
-- sqlstate equals its registered one. TDD C-15 rewritten from the
-- function-granular stub (which a single typed site per function satisfied)
-- to the per-SITE probe, plus the registered-half and the live-agreement
-- control.


CREATE OR REPLACE FUNCTION ckp._dispatch_route(p_verb text, p_payload jsonb)
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
  v_proj text := ckp._project();
  -- 0.4.80 — NO MANUFACTURED KEY. This COALESCE substituted the literal
  -- 'pgck-localhost' whenever nothing was configured, so absence produced a
  -- shared secret instead of a refusal. The key now comes from ckp.config,
  -- minted per install; ckp.seal already refuses when it is missing, and that
  -- refusal is the point.
  v_idk  text := COALESCE(NULLIF(current_setting('ckp.identity_key', true), ''),
                          (SELECT v FROM ckp.config WHERE k = 'identity_key'));
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
  -- Resolve against the CALLING project, not a fixed kernel. This asked
  -- registry_lookup('pgck', ...) for every caller, so a verb registered by any
  -- other kernel was invisible and every non-pgck workspace got
  -- unknown_affordance. It looked correct only because the seed and the
  -- registrars were hard-coded to the same literal -- writer and reader wrong
  -- in the same direction. (smoke-s4 s41: registered under 's41-test',
  -- resolved under 'pgck'.)
  v_aff   := ckp.registry_lookup(v_proj, v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'sqlstate', '42704', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'sqlstate', '0A000', 'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable', 'sqlstate', '55000',
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
  -- 0.4.51: `@type` and a nested `{body:{type}}` route here TOO, so the teaching
  -- refusal is reachable. Without this a caller following JSON-LD habit fell
  -- through to the task.create concretion and was told "kernel and title
  -- required" — an error about a verb it did not call, naming fields it never
  -- heard of. create_typed answers `type_not_readable_here` and names the two
  -- shapes that ARE read. Routing on a key it will then refuse is deliberate:
  -- the alternative is a correct-looking error from the wrong handler, which is
  -- the class of misdirection F9 filed.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type' OR p_payload ? '@type'
             OR (p_payload ? 'body' AND ((p_payload->'body') ? 'type' OR (p_payload->'body') ? '@type')))
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

  -- 0.4.51 — THE CHECKER SURFACE. Every one of these answered a question this
  -- kernel had to answer with a hand-written psql probe in PASS-30, which is a
  -- second surface by definition: a check that lives in someone's scratch
  -- directory cannot be re-run by the party who needs it, and it is not a fact.
  -- As governed verbs they are callable by any identity the kernel grants,
  -- their answers are attributable, and the negative control ships WITH the
  -- gate instead of beside it.
  WHEN 'wave.signals' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.signals'),
                    ckp.wave_signals(p_payload));

  -- one-version alias (0.4.63): routes, answers, and says where to go. Removed
  -- next release — nothing tagged ever carried the old name.
  WHEN 'wave.oracle' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.oracle'),
                    ckp.wave_signals(p_payload))
        || jsonb_build_object('deprecated', 'wave.oracle is wave.signals; this alias is removed next release');

  WHEN 'adoption.check' THEN
    res := ckp.adoption_check(p_payload);

  WHEN 'wave.project' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.project'),
                    ckp.wave_project_spine(p_payload));

  WHEN 'surface.typecheck' THEN
    res := ckp.surface_typecheck(p_payload, v_proj);

  WHEN 'surface.unshaped' THEN
    res := ckp.surface_unshaped(v_proj);

  -- 0.4.83 (B7) — the refusal registry is itself learnable through the door
  -- (a check that is not a verb does not exist): the closed set of refusal
  -- codes, their typed sqlstate classes, and what each teaches.
  WHEN 'surface.refusals' THEN
    -- 0.4.90 (Q-2 + Q-3, CK.Lib.Js). registryDigest is sha256 over the ORDERED
    -- code set, so a client caches on the digest and re-reads only when the set
    -- actually moves. plane rides per row and is NULL where the classification
    -- would be a guess (see the registry table comment).
    -- NOTE: jsonb_strip_nulls is deliberately NOT applied to plane — a stripped
    -- key and an explicit null are different answers, and "we did not classify
    -- this one" must survive the wire. Only `teaches` is stripped when absent.
    res := jsonb_build_object('ok', true,
      'count', (SELECT count(*) FROM ckp.refusal_registry),
      'registryDigest', (SELECT encode(digest(string_agg(code, E'\n' ORDER BY code), 'sha256'), 'hex')
                           FROM ckp.refusal_registry),
      'planes', (SELECT jsonb_object_agg(k, c) FROM (
                   SELECT COALESCE(plane,'unclassified') k, count(*) c
                     FROM ckp.refusal_registry GROUP BY 1) t),
      'refusals', COALESCE((SELECT jsonb_agg(
                    jsonb_strip_nulls(jsonb_build_object(
                      'code', code, 'sqlstate', sqlstate, 'teaches', teaches))
                    || jsonb_build_object('plane', plane)
                    ORDER BY sqlstate, code)
                  FROM ckp.refusal_registry), '[]'::jsonb),
      'note', 'an ok:false whose error is not in this set is fault-shaped, not a refusal. '
              'plane:null means the classification would be a guess — 22023 and 42704 each '
              'carry codes of both planes; cache on registryDigest, not on count.');

  WHEN 'surface.declared' THEN
    res := ckp.surface_declared(p_payload, v_proj);

  WHEN 'surface.grounding' THEN
    res := ckp.surface_grounding(p_payload, v_proj);

  WHEN 'surface.explain' THEN
    res := ckp.surface_explain(p_payload, v_proj);

  WHEN 'fleet.adoptions' THEN
    res := ckp.fleet_adoptions(p_payload);

  WHEN 'project.resolve' THEN
    res := ckp.project_resolve(p_payload);

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
    res := res || ckp._read_verdict(jsonb_array_length(res->'kernels'));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      -- 0.4.66: proofs are PLURAL since obligations (0.4.65). `proof` stays the
      -- byte-proof (the hmac row — what `verified` checks) so existing readers
      -- keep their meaning; `proofs` carries EVERY row, obligations included —
      -- "which agreed checks did this seal pass" must be readable at the door,
      -- or the obligation mark exists only for parties with table access.
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid AND method='hmac+sha256' ORDER BY id DESC LIMIT 1),
        'proofs', COALESCE((SELECT jsonb_agg(jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) ORDER BY id) FROM ckp.proof WHERE about=tid),'[]'::jsonb),
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
             p_payload->>'projectKind');

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
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(tid);
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
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(tid);
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
  -- 0.4.51 — THE EDGE CLASS IS THE CALLER'S TO NAME, AND WAS A DEFAULT NOTHING
  -- DECLARED. This sealed N||'Edge' = urn:ckp:board/Edge unconditionally. That
  -- class is declared in ONE file, examples/example.kernel.ttl, which no module
  -- can load (import_module knows {task, goal}), so the path COULD NOT SEAL FOR
  -- ANY PARTICIPANT ON ANY KERNEL SURFACE, regardless of grants — measured by
  -- pgCK.MCP as F6 and re-measured here: SELECT ?g ?p WHERE { GRAPH ?g { ?s ?p
  -- <urn:ckp:board/Edge> } } returns ZERO ROWS fleet-wide.
  --
  -- Worse, 0.4.42's own comment in ckp._type_admitted asserted the exit
  -- condition was met — "urn:ckp:board/{Task,Goal,Edge,Message} now carry shapes
  -- in the project kernel graph". They do not. That sentence is deleted with
  -- this default; a comment claiming a gate is a claim, and R1 applies to
  -- claims about our own code exactly as it applies to shapes.
  --
  -- The kernel declares what an edge IS; the substrate refuses what violates
  -- that. So the class comes from the caller and the property IRIs follow ITS
  -- namespace — the same rule create_typed's fallback already uses. A caller
  -- that names no class is REFUSED with the reason, never sealed under a class
  -- nobody declared.
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_etype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_ens   text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF v_etype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','edge_type_required',
          'hint','instance.link requires {type}: the edge class THIS kernel declares (sh:targetClass or a declared rdfs:Class/owl:Class in its composed surface). There is no substrate default — the former one, urn:ckp:board/Edge, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_etype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','instance.link {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Edge');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        v_ens := regexp_replace(v_etype, '[^/#]*$', '');    -- the declared class's namespace
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', v_etype, '@id', 'ckp://Edge#'||eid,
          v_ens||'source', src, v_ens||'predicate', pred, v_ens||'target', tgt, v_ens||'topic', topic,
          v_ens||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'type',v_etype,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj)) || ckp._stamped(eid);
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  -- 0.4.51 — the SAME defect as edge.create, one class along, and untested by
  -- the party who found the first: this sealed N||'Message' = urn:ckp:board/
  -- Message, declared by no loadable module, so notify could not seal either.
  -- The class is the caller's to name; the property IRIs follow its namespace.
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := p_payload->>'predicate';
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
            v_mtype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_mns   text;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSIF v_mtype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','message_type_required',
          'hint','notify requires {type}: the message class THIS kernel declares. There is no substrate default — the former one, urn:ckp:board/Message, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_mtype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','notify {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Message');
      ELSE
        v_mns := regexp_replace(v_mtype, '[^/#]*$', '');
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', v_mtype, '@id', 'ckp://Message#'||mid,
          v_mns||'from', frm, v_mns||'to', tgt, v_mns||'predicate', pred, v_mns||'body', bdy, v_mns||'topic', topic,
          v_mns||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(v_mns||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'type',v_mtype,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(mid);
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'sqlstate', '0A000', 'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._module_gate(p_project text, p_module text, p_verb text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  IF p_project IS NOT NULL AND p_module = ANY(ckp._adopted_graphs(p_project)) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'module_not_adopted', 'sqlstate', '55000',
    'module', p_module, 'verb', p_verb, 'kernel', p_project);
END;
$function$;

CREATE OR REPLACE FUNCTION ckp._refusal_envelope(p_res jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  r ckp.refusal_registry%ROWTYPE;
BEGIN
  IF p_res IS NULL
     OR p_res->>'ok' IS DISTINCT FROM 'false'
     OR COALESCE((p_res->>'delegate')::boolean, false) THEN
    RETURN p_res;
  END IF;
  SELECT * INTO r FROM ckp.refusal_registry WHERE code = p_res->>'error';
  IF NOT FOUND THEN
    RETURN p_res;   -- fault-shaped: not in the closed set, stays unflagged
  END IF;
  p_res := p_res || jsonb_build_object('refused', true,
             'sqlstate', COALESCE(p_res->>'sqlstate', r.sqlstate));
  IF r.teaches IS NOT NULL AND NOT p_res ? 'hint' THEN
    p_res := p_res || jsonb_build_object('hint', r.teaches);
  END IF;
  RETURN p_res;
END;
$function$;

-- 0.4.84 (P3 / HANDOVER B4) — the reply carries what the seal wrote. ONE reader
-- over the STORED body (the same truths the gate stamped), appended by every
-- write site: the producer is no longer blind to its own seal, and cklib drops
-- its D7 shim. The four mechanisms ride as four keys, never aggregated;
-- conformsToShape absent means M4 ABSENT (admitted, judged by nothing) — the
-- key is withheld, never faked to null.
-- 0.4.84 (B2) — a read reply carries its completeness verdict. ONE builder:
-- with the TOTAL known, complete is a measured fact (returned >= total, and a
-- shortfall names itself 'truncated'); with only a limit, an answer that FILLS
-- the limit can honestly claim no more than 'possibly_truncated'. A row count
-- without its verdict is not a count.
CREATE OR REPLACE FUNCTION ckp._read_verdict(p_returned int, p_limit int DEFAULT NULL, p_total bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT jsonb_build_object('completeness', jsonb_strip_nulls(jsonb_build_object(
    'returned', p_returned,
    'limit',    p_limit,
    'total',    p_total,
    'verdict',  CASE
      WHEN p_total IS NOT NULL AND p_returned >= p_total THEN 'complete'
      WHEN p_total IS NOT NULL                           THEN 'truncated'
      WHEN p_limit IS NULL OR p_returned < p_limit       THEN 'complete'
      ELSE 'possibly_truncated' END)));
$function$;

CREATE OR REPLACE FUNCTION ckp._stamped(p_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE((SELECT jsonb_strip_nulls(jsonb_build_object(
    'createdBy',       i.body->>'https://conceptkernel.org/ontology/v3.11/core#createdBy',
    'producedBy',      i.body->>'https://conceptkernel.org/ontology/v3.11/core#producedBy',
    'sealedAtEpoch',   i.body->'https://conceptkernel.org/ontology/v3.11/core#sealedAtEpoch',
    'conformsToShape', i.body->>'https://conceptkernel.org/ontology/v3.11/core#conformsToShape'))
  FROM ckp.instances i WHERE i.id = p_id), '{}'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN ckp._refusal_envelope(ckp._dispatch_route(p_verb, p_payload));
END;
$function$;

COMMENT ON FUNCTION ckp.dispatch(text, jsonb) IS
  'The one door (CKP §2.2). Routes via ckp._dispatch_route, then ckp._refusal_envelope '
  'normalizes every refusal against ckp.refusal_registry — the declared closed set '
  'of refusal codes — so {ok:false, refused:true, sqlstate} is one law for every '
  'construction site (B7; cklib PASS-2 ISSUE-6/7). A reply whose error is not in '
  'the registry is fault-shaped, and that absence is deliberate.';

CREATE OR REPLACE FUNCTION ckp.enqueue_materialize(p_concept text, p_scope jsonb, p_formula text, p_epoch bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE wm bigint := ckp._source_watermark(p_scope);
BEGIN
  INSERT INTO ckp.materialize_job(concept,scope,formula,epoch,watermark,phase)
  VALUES (p_concept,p_scope,p_formula,p_epoch,wm,'queued')
  ON CONFLICT (concept) DO UPDATE SET scope=EXCLUDED.scope, formula=EXCLUDED.formula,
    epoch=EXCLUDED.epoch, watermark=EXCLUDED.watermark, enqueued_at=now();
  RETURN jsonb_build_object('ok',true,'recompute_in_progress',true);
END $function$
;

CREATE OR REPLACE FUNCTION ckp.adopt_kernel_ttl(p_ttl text, p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_iri   text := format('urn:ckp:%s/kernel/ck', p_project);
  v_g     bigint;
  v_quads bigint;
BEGIN
  IF p_ttl IS NULL OR btrim(p_ttl) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ttl_required', 'sqlstate', '22004');
  END IF;
  -- get-or-create the project's CK-loop graph (after ckp.boot has claimed the reserved
  -- core/kernel ids, so the IRI-variant add_graph never steals id 1/2 — the s34 lesson).
  v_g := pgrdf.add_graph(v_iri);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_g, v_iri || '#');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'sqlstate', '42601', 'detail', SQLERRM);
  END;
  PERFORM pgrdf.materialize(v_g);
  RETURN jsonb_build_object('ok', true, 'project', p_project, 'ck_iri', v_iri,
                            'kernel_graph', v_g, 'quads', v_quads);
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
  v_proj      text := ckp._project();
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
  END IF;
  -- 0.4.99 (C-2) — OWNERSHIP ON APPLY, IN THE SUBSTRATE.
  --
  -- ckp.apply checked that the proposal exists, is pending, and has enough
  -- DISTINCT non-anonymous approvals. That is all. The owner-applies rule lived
  -- only in a client — CK-dev's Action panel offers the button to the owner and
  -- notes that "a counterparty applying lands the change in THEIR graph", which
  -- is the substrate's actual behaviour showing through a screen. A screen is
  -- not a gate: any party with a credential could apply a quorum-met proposal
  -- and land somebody else's governed change wherever they stood.
  --
  -- Quorum answers "did enough parties agree". It does not answer "may THIS
  -- party enact it". Those are different questions and only the first was asked.
  --
  -- Bind only what declared itself, exactly as C-1's quorum floor does: if the
  -- target project seals ckp:ownedBy, the applier must BE that owner; if no
  -- owner is declared, nothing is imposed. Inventing an owner for a project that
  -- never named one would be the substrate choosing on the caller's behalf —
  -- the defect 0.4.81 fixed by defaulting projectKind to NULL.
  DECLARE
    v_about_proj text := substring(v_about from '^urn:ckp:([a-z0-9-]+)/');
    v_owner      text;
    v_me         text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_about_proj IS NOT NULL THEN
      SELECT i.body->>(C||'ownedBy') INTO v_owner FROM ckp.instances i
       WHERE i.body->>'@id' = 'urn:ckp:project:'||v_about_proj
         AND i.body->>'type' = C||'Project'
       ORDER BY i.ts_created DESC LIMIT 1;
      IF v_owner IS NOT NULL THEN
        v_me := CASE WHEN v_me IS NULL THEN NULL
                     ELSE 'urn:ckp:participant:'||ckp._slug(v_me) END;
        IF v_me IS DISTINCT FROM v_owner THEN
          RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
            'error', 'not_owner',
            'about', v_about, 'owner', v_owner,
            'hint', format('proposal %L targets %L, which is owned by %s. Quorum answers whether '
                           'enough parties AGREED; it does not answer whether THIS party may enact '
                           'the change. Ask the owner to apply, or propose against a project you '
                           'own. Applying from elsewhere would land this change in your own graph, '
                           'which is not what the voters approved.',
                           v_about, v_about_proj, v_owner));
        END IF;
      END IF;
    END IF;
  END;

  -- Placed BEFORE the proposal lookup deliberately. "May this party enact
  -- changes to this about-graph" is answerable from `about` alone, and asking it
  -- first means a stranger learns nothing about whether a proposal exists — an
  -- ownership refusal should not double as an existence oracle.
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'sqlstate', '42704', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'sqlstate', '55000', 'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 0.4.102 (C-2, SECOND HALF) — THE GATE MUST SIT ON THE PATH THE LIVE VERB
  -- TAKES. The 0.4.99 ownership check above parses the CALLER'S `about` for a
  -- urn:ckp:<proj>/ prefix — but a real apply's `about` is the Proposal @id
  -- (ckp://Proposal#…), which that regex never matches, so the live path was
  -- ungated: any party could apply a quorum-met proposal against an owned
  -- project by addressing the proposal, which is the only way anyone ever
  -- addresses one. Found by the TDD E-1 exercise — the FIRST full
  -- propose→vote→apply the ledger ever ran — not by C-2's probe, which asked
  -- the question in the one spelling the gate could hear. A check that cannot
  -- fail the thing it claims is not a check.
  --
  -- Re-derive the target project from the SEALED proposal's own `about` —
  -- written at propose from server state, never the applier's word — and ask
  -- the same question the pre-lookup gate asks, with the same rule: a declared
  -- owner binds, an undeclared one imposes nothing.
  DECLARE
    v_tgt_proj  text := substring(v_prop->>(C||'about') from '^urn:ckp:([a-z0-9-]+)/');
    v_tgt_owner text;
    v_applier   text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_tgt_proj IS NOT NULL THEN
      SELECT i.body->>(C||'ownedBy') INTO v_tgt_owner FROM ckp.instances i
       WHERE i.body->>'@id' = 'urn:ckp:project:'||v_tgt_proj
         AND i.body->>'type' = C||'Project'
       ORDER BY i.ts_created DESC LIMIT 1;
      IF v_tgt_owner IS NOT NULL THEN
        v_applier := CASE WHEN v_applier IS NULL THEN NULL
                          ELSE 'urn:ckp:participant:'||ckp._slug(v_applier) END;
        IF v_applier IS DISTINCT FROM v_tgt_owner THEN
          RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
            'error', 'not_owner',
            'about', v_prop->>(C||'about'), 'owner', v_tgt_owner,
            'hint', format('this proposal targets %s, which is owned by %s. Quorum answers '
                           'whether enough parties AGREED; it does not answer whether THIS '
                           'party may enact the change. Ask the owner to apply.',
                           v_prop->>(C||'about'), v_tgt_owner));
        END IF;
      END IF;
    END IF;
  END;
  -- 0.4.98 (C-1 / L-8): the floor binds at APPLY as well, so a proposal sealed
  -- at quorum 1 before the project declared `shared` — or before this shipped —
  -- cannot still be self-applied. GREATEST, never replacement: a proposal that
  -- asked for MORE than the floor keeps what it asked for.
  v_quorum := GREATEST(COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1),
                       ckp._quorum_floor(v_proj));
  -- 0.4.62 — QUORUM IS DISTINCT ACCOUNTABLE PARTIES. This counted VOTES: one
  -- identity voting twice was two approvals, and ckp.seal mints a FRESH
  -- anon:<uuid> per unattributed call, so N naked-path seals presented as N
  -- distinct parties — one psql caller could manufacture any quorum (ck-dev's
  -- finding-1786732252462817000; measured unexploited, 3 anon votes on 3
  -- proposals). Now: distinct createdBy, anon:* excluded — an identity nobody
  -- can be held to cannot be a party to a decision. The three historical
  -- anon-applied proposals stand as fenced history, not precedent.
  SELECT count(DISTINCT body->>(C||'createdBy')) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve'
      AND COALESCE(body->>(C||'createdBy'),'') NOT LIKE 'urn:ckp:participant:anon:%';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'sqlstate', '55000', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  v_op := v_prop->>(C||'proposalOp');

  -- 4a. GRAPH APPLY (shape ops) — translate the op into the kernel graph (the §5.2 EFFECT).
  BEGIN
    v_ttl := ckp._op_to_ttl(v_prop);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_translate_failed', 'sqlstate', '22023', 'detail', SQLERRM);
  END;
  IF v_ttl IS NOT NULL THEN
    v_ga := ckp.apply_shape_ttl(v_ttl, v_proj);
    IF (v_ga->>'ok') IS DISTINCT FROM 'true' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'graph_apply_failed', 'sqlstate', '55000', 'detail', v_ga);
    END IF;
    v_applied := jsonb_build_object('graph_changed', true, 'applied_quads', v_ga->'applied_quads');
  END IF;

  -- 4a-bis. KERNEL POLICY (0.4.95, C-4). No shape projection — _op_to_ttl returns
  -- NULL for this op and the graph is untouched. The policy lives on the SEALED
  -- Kernel instance, so it is applied as a governed patch through the same path a
  -- client would use, and that is the entire point:
  --
  --   NOTHING HERE CHECKS A RANGE. The law already declares every bound —
  --   weightAssent >= 0, weightDissent <= 0, weightImplicit in [0,1],
  --   decayLambda >= 0, thresholdDefer >= 0, and thresholdDiscard sh:lessThan
  --   thresholdPromote, which is the only cross-property invariant of the seven
  --   and the one no per-property constraint can catch. Measured on the composed
  --   surface before this was written: an in-range set conforms, and each of those
  --   four violations is refused. A projector carrying its own copy of the bounds
  --   would be a second implementation of a rule that already exists — the exact
  --   defect D-1 corrected one layer over. You do not enforce your own shape; you
  --   declare it, and the ground refuses what violates it.
  --
  --   update_typed is composed-aware, so an UNDECLARED field is refused by name
  --   (undeclared_patch_key) rather than minted, and ckp.seal runs the gate that
  --   enforces the bounds. Both halves come for free.
  IF v_op = 'set_kernel_policy' THEN
    DECLARE
      v_kid   text := 'urn:ckp:'||v_proj||'/kernel';
      -- BARE key, matching every other reader (lines 2381, 3151, 3168). The
      -- body stores proposalOp under its full IRI and proposalDetail bare; that
      -- inconsistency is noted at 2441 as a known family and is not mine to fix
      -- here — but writing C||'proposalDetail' would have silently read NULL and
      -- refused every policy proposal with "needs {field, value}".
      v_field text := v_prop->'proposalDetail'->>'field';
      v_val   jsonb := v_prop->'proposalDetail'->'value';
      v_upd   jsonb;
    BEGIN
      IF v_field IS NULL OR v_val IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'sqlstate', '22023',
          'hint', 'set_kernel_policy needs {field, value}');
      END IF;
      v_upd := ckp.update_typed(jsonb_build_object(
                 'id', v_kid,
                 'patch', jsonb_build_object(C||v_field, v_val)));
      IF (v_upd->>'ok') IS DISTINCT FROM 'true' THEN
        -- the refusal travels VERBATIM. A policy refused by the shape gate must
        -- say which clause refused it, not be flattened into "apply failed".
        RETURN jsonb_build_object('ok', false, 'error', 'policy_apply_refused', 'sqlstate', '55000',
          'field', v_field, 'detail', v_upd);
      END IF;
      v_applied := v_applied || jsonb_build_object('policy', jsonb_build_object('field', v_field, 'value', v_val));
    END;
  END IF;

  -- 4b. CASCADE — epoch advance, and it MUST produce a sealed Materialization
  --     (P0-E, pgCK#28). The epoch is not a counter: the bump recompiles the
  --     plan surface (compile_plans + plan_cache_clear inside bump_epoch), and
  --     the rebuild is SEALED as a first-class ckp:Materialization that
  --     produces a ckp:Epoch carrying the surface digest. All in THIS txn: if
  --     the Materialization or Epoch fails its shape gate, the whole apply
  --     rolls back — a bumped epoch with no valid Materialization cannot
  --     commit. "Show me the Materialization that produced this epoch, and
  --     re-derive the surface at that epoch" is answerable from the seals.
  DECLARE
    -- this project's epoch, not a fixed kernel's: reading one kernel's epoch
    -- while bumping another's makes every other kernel restart from 1.
    -- 0.4.90 (§2): was COALESCE(...,1) while all six read sites use 0 — the two
    -- planes rendered the SAME absent row as different numbers. One convention now.
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
    v_comp_e int;
    v_srcd   text;
    v_surfd  text;
    v_kiri   text := format('urn:ckp:%s/kernel/ck', v_proj);
    v_eiri   text;
    v_miri   text;
  BEGIN
    -- bump THIS project's epoch. Hard-coded, it advanced one kernel's epoch on
    -- every apply by anyone, so every other kernel's epoch never moved and its
    -- plans were recompiled under a name it does not own.
    v_epoch := ckp.bump_epoch(v_proj);           -- recompiles plans + clears cache (same txn)
    v_comp_e := ckp._composed_shapes(v_proj);    -- rebuild the enforcement surface from the new shapes
    v_srcd  := ckp._surface_digest(pgrdf.add_graph(v_kiri));   -- the governed source shapes
    v_surfd := ckp._surface_digest(v_comp_e);                  -- the enforcement surface produced
    v_eiri  := format('urn:ckp:%s/epoch/%s', v_proj, v_epoch);
    v_miri  := format('urn:ckp:%s/materialization/%s', v_proj, v_epoch);
    -- the Epoch resource: the position, named by the digest of its surface.
    -- 0.4.67: TWO digest planes, each named for what it pins. surfaceDigest is
    -- the COPY plane — this store's bytes, what surface.check compares in-store
    -- and what the digest-match obligation consults; it moves on reload and is
    -- never cross-bench identity. structuralDigest is the plane that survives
    -- reload (first-degree bnode-signature algorithm, fleet-shared) — the one a
    -- third party CAN recompute from the published modules, and the one a
    -- cross-store verifier cites. Nobody minted early: this key ships in the
    -- same act as the code that derives it.
    PERFORM ckp.seal('epoch-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Epoch', '@id', v_eiri,
      C||'epoch', to_jsonb(v_epoch),
      C||'surfaceDigest', v_surfd,
      C||'structuralDigest', ckp._structural_digest(v_comp_e)));
    -- 0.4.97 (E-1): the live epoch row records the surface it ran under, from the
    -- SAME v_surfd that was just sealed into the Epoch. One computation, three
    -- writers — the table cannot drift from the seal, which is the whole failure
    -- D-1 was about one layer over.
    UPDATE ckp.kernel_epoch SET surface_digest = v_surfd WHERE kernel = v_proj;

    -- the Materialization: the sealed rebuild that produced that epoch.
    PERFORM ckp.seal('mat-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Materialization', '@id', v_miri,
      C||'materializes', v_kiri,
      C||'fromEpoch', to_jsonb(v_from),
      C||'toEpoch', to_jsonb(v_epoch),
      C||'sourceDigest', v_srcd,
      C||'surfaceDigest', v_surfd,
      C||'producesEpoch', v_eiri));
  END;

  -- 4c. QUERY AFFORDANCE (Tier 2 3/3b) — an add_affordance carrying query text is compiled into
  --     ckp.plans + registered plane='query', keyed to the new epoch (governed, sealed).
  IF v_op = 'add_affordance' AND (v_prop->'proposalDetail' ? 'query') THEN
    BEGIN
      PERFORM ckp.register_query_affordance(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('query_affordance', v_prop->'proposalDetail'->>'verb');
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'affordance_register_failed', 'sqlstate', '55000', 'detail', SQLERRM);
    END;
  END IF;

  -- 4d. PROOF OBLIGATION (0.4.65, §5b) — the seal-exit dual of 4c: where
  --     add_affordance opens a dispatch entry, add_proof_obligation closes the
  --     seal's exit with a check every future seal of the target type must
  --     satisfy. The registry row is the projected change (P0-E honoured);
  --     removal travels the same governed road with detail.active=false.
  IF v_op = 'add_proof_obligation' THEN
    BEGIN
      PERFORM ckp.register_proof_obligation(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('proof_obligation', v_prop->'proposalDetail'->>'obligation',
                                                   'obligation_active', COALESCE(v_prop->'proposalDetail'->>'active','true'));
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'obligation_register_failed', 'sqlstate', '55000', 'detail', SQLERRM);
    END;
  END IF;

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  -- 0.4.90 (L-6 / R5.3, CK.Lib.Js) — THE SUCCESS PATH CARRIES THE PAIR TOO.
  -- The REFUSAL path returned approvals AND quorum (see quorum_not_met above);
  -- the success path returned approvals alone, so a caller reading a successful
  -- apply could not tell 1-of-1 from 3-of-3 without a second read. The pair is
  -- the whole meaning: an approval count without the bar it cleared is not a
  -- number. `rehearsal` states the standing rule out loud rather than leaving
  -- the reader to infer it — quorum 1 means proposer, voter and applier may be
  -- the same identity, which is a rehearsal of governance, not consensus, and
  -- this substrate says so every time rather than once in a document.
  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'quorum', v_quorum,
                            'rehearsal', (v_quorum = 1),
                            'quorumNote', CASE WHEN v_quorum = 1
                              THEN 'quorum 1 — proposer, voter and applier may be one identity. This is REHEARSAL, not consensus.'
                              ELSE format('quorum %s cleared by %s DISTINCT non-anonymous identities', v_quorum, v_approvals) END,
                            'applied', v_applied,
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
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'sqlstate', '42601', 'detail', SQLERRM);
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
    RETURN jsonb_build_object('ok', false, 'error', 'fence_violation', 'sqlstate', '42501', 'forbidden_predicates', v_forbidden);
  END IF;

  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  PERFORM ckp._graph_apply(v_scratch, v_kernel);
  PERFORM pgrdf.materialize(v_kernel);
  PERFORM pgrdf.clear_graph(v_scratch);
  RETURN jsonb_build_object('ok', true, 'applied_quads', v_quads, 'kernel_graph', v_kernel);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.concept_match(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_term   text := p_payload->>'term';
  v_proj   text := ckp._project();
  v_limit  int  := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 10), 1), 100);
  v_term_esc text;
  v_plan   jsonb;
  v_stmt   text;
  v_rows   jsonb;
BEGIN
  IF v_term IS NULL OR length(v_term) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'sqlstate', '22023', 'term', v_term);
  END IF;

  -- the GOVERNED query: latest-epoch concept.match plan.
  -- PLAN RESOLUTION = your own first, then the substrate floor. A plan the
  -- calling project registered wins; otherwise fall back to the one seeded at
  -- install, which belongs to no kernel because install runs before any kernel
  -- exists. Reading ONLY the floor made every project share one kernel's plans;
  -- reading ONLY v_proj made the seeded substrate verbs unreachable for
  -- everyone (smoke-s4 s32). Both halves are needed until the seed itself stops
  -- naming a kernel.
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel IN (v_proj, 'pgck') AND verb = 'concept.match'
   ORDER BY (kernel = v_proj) DESC, epoch DESC LIMIT 1;

  IF v_plan IS NOT NULL AND v_plan->>'kind' = 'sparql' THEN
    -- BIND (not reject): escape the term for the SPARQL string literal so any term is contained —
    -- an injection-shaped term becomes a literal that matches nothing (never breaks the query).
    v_term_esc := replace(replace(replace(v_term, '\', '\\'), '"', '\"'), chr(10), '\n');
    v_stmt := replace(v_plan->>'statement', '$graph$', format('urn:ckp:%s/instances', v_proj));
    v_stmt := replace(v_stmt, '$term$', v_term_esc);
    -- run + RANK in pgCK (exact > prefix > contains; the governed query supplies the matches).
    SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
      INTO v_rows
    FROM (
      SELECT j->>'id' AS id, j->>'label' AS lbl,
        CASE WHEN lower(j->>'label') = lower(v_term)         THEN 1
             WHEN lower(j->>'label') LIKE lower(v_term)||'%' THEN 2
             ELSE 3 END AS rnk
      FROM pgrdf.sparql(v_stmt) j
      LIMIT v_limit
    ) t;
    RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', true,
                              'count', COALESCE(jsonb_array_length(v_rows), 0),
                              'candidates', COALESCE(v_rows, '[]'::jsonb));
  END IF;

  -- fallback: the legacy in-table label search (no governed plan present).
  SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
  INTO v_rows FROM (
    SELECT id, lbl,
      CASE WHEN lower(lbl) = lower(v_term)         THEN 1
           WHEN lower(lbl) LIKE lower(v_term)||'%' THEN 2
           ELSE 3 END AS rnk
    FROM (
      SELECT id, COALESCE(body->>'rdfs:label',
                          body->>'urn:ckp:board/title',
                          body->>'title') AS lbl
      FROM ckp.instances
    ) s
    WHERE lbl ILIKE '%'||v_term||'%'
    ORDER BY rnk
    LIMIT v_limit
  ) t;
  RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', false,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'candidates', COALESCE(v_rows, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- 0.4.51: read the SAME payload shapes ckp.validate_instance reads. It did
  -- COALESCE(p_payload->'body', p_payload) and this did not, so a nested
  -- {body:{type,…}} VALIDATED and then failed to CREATE — validate ⟺ seal
  -- broken at the envelope, one level above where it was broken at the
  -- property map. Both are closed in this version, in the same act, because
  -- fixing one and not the other just moves the disagreement.
  v_in      jsonb := CASE WHEN jsonb_typeof(p_payload->'body') = 'object'
                            AND ((p_payload->'body') ? 'type')
                          THEN p_payload->'body' ELSE p_payload END;
  v_type    text := v_in->>'type';
  v_proj    text := ckp._project();
  -- F-A / P0-C (pgCK#26): identity is SERVER-DERIVED from the verified
  -- connection (the ckp.requester GUC the trusted ingress sets from the
  -- NATS-verified bearer), NEVER the client payload. A payload {sub} is
  -- ignored — it cannot forge created_by or the participant claim. This is
  -- the same rule task.create and notify already carry; the generic path
  -- was the last reader of payload sub (measured: s58's instance.create
  -- case sealed participant:attacker before this fix).
  v_sub     text := current_setting('ckp.requester', true);
  N         text := 'urn:ckp:board/';       -- v3.7 core NS (gate + task.create)
  v_core    text[] := ARRAY['lifecycle_state'];                       -- recognized core keys → core NS
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    -- 0.4.51 — ABSENT is not the same as PRESENT-BUT-NOT-READABLE-HERE, and the
    -- old error said the first when the second was true. A caller following
    -- JSON-LD habit sends {"@type": …} and is told it gave no type; a caller
    -- nesting {"type": …, "body": {…}} is told the same. Both then re-send the
    -- one field they already sent. pgCK.MCP lost two calls to exactly this
    -- (F9) before reading the spec. Name the shape instead of the field.
    IF p_payload ? '@type' OR (jsonb_typeof(p_payload->'body') = 'object'
                               AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here', 'sqlstate', '42704',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}} — the same two shapes instance.validate reads. NOT accepted: @type, which is never read.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required', 'sqlstate', '22004',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri', 'sqlstate', '22023',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 0.4.51: the SAME map validate_instance uses. It read the kernel graph while
  -- validate read composed, so validate and create could resolve one JSON key to
  -- two different IRIs. See ckp._propmap.
  v_propmap := ckp._propmap(v_type, v_proj);

  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_in)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id', 'participant');     -- control keys, not data (sub/participant: identity is never payload)
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                             -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                                 -- declared localname -> its path IRI
    ELSIF v_key = ANY(v_core) THEN
      v_keyiri := N || v_key;                                        -- v3.7 core key -> core NS (gate + task.create)
    ELSE
      v_keyiri := v_ns || v_key;                                     -- other undeclared -> under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);         -- `->` value: preserves number/bool/object types
  END LOOP;

  v_body := v_body || jsonb_build_object(
    'urn:ckp:board/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    -- created_by from the VERIFIED requester (same shape as task.create), and
    -- the participant claim seal maps to core#participant — also verified.
    v_body := v_body || jsonb_build_object(
      N||'created_by', 'urn:ckp:participant:'||ckp._slug(v_sub),
      'participant', jsonb_build_object('sub', v_sub));
  END IF;

  PERFORM ckp.seal(v_iid, v_body);

  -- 0.4.72: the guidance band rides the reply. ckp.seal parked any
  -- Warning/Info-severity results in a txn-local GUC (cleared at each seal
  -- start); surfacing them here is what makes warning-shapes GUIDANCE instead
  -- of noise — sealed, and told why the fleet would prefer it shaped better.
  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1))
    || ckp._stamped(v_iid)
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_kernel_urn text, p_payload jsonb, p_identity text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  res jsonb;
BEGIN
  -- Transitional minimal surface (CI-A-2). The full §2.2 fail-fast order lands in
  -- CI-B/CI-C/CI-D; here we prove the locked door is usable as definer.
  CASE p_verb
    WHEN 'instances.count' THEN
      res := jsonb_build_object('ok', true, 'count', (SELECT count(*) FROM ckp.instances));
    WHEN 'instance.verify' THEN
      res := jsonb_build_object('ok', true, 'id', p_payload->>'id',
                                'verified', ckp.verify(p_payload->>'id'));
    ELSE
      -- unknown verb -> the delegation seam (becomes a sealed-delegation fact in CI-B-4).
      res := jsonb_build_object('ok', false, 'delegate', true,
                                'sqlstate', '0A000', 'error', 'verb not governed yet (CI-B): ' || p_verb);
  END CASE;
  RETURN res || jsonb_build_object('kernel', p_kernel_urn);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.explain(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id   text := p_payload->>'id';
  v_body jsonb;
  v_mat  jsonb;
BEGIN
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'sqlstate', '42704', 'id', v_id);
  END IF;
  -- direct-vs-inferred from the engine is_inferred column (graph-wide summary for the alpha;
  -- the per-node derivation chain is deferred — engine ask #1).
  BEGIN
    SELECT jsonb_build_object('direct',   count(*) FILTER (WHERE NOT is_inferred),
                              'inferred', count(*) FILTER (WHERE is_inferred))
    INTO v_mat FROM pgrdf._pgrdf_quads;
  EXCEPTION WHEN OTHERS THEN
    v_mat := jsonb_build_object('note', 'is_inferred available; counts unavailable: '||SQLERRM);
  END;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'materialization', v_mat,
                            'derivation_chain', 'deferred (engine ask #1)');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.germinate_kernel(p_project text, p_label text DEFAULT NULL,
                                                -- 0.4.81: DEFAULT NULL, not
                                                -- 'personal'. NULL is the ABSENCE
                                                -- itself; ProjectShape then refuses
                                                -- on minCount/sh:in and names the
                                                -- clause, instead of the substrate
                                                -- choosing a kind nobody asked for.
                                                p_kind text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_law_epoch boolean;
  v_sub   text := NULLIF(current_setting('ckp.requester', true), '');
  v_owner text;
  v_label text := COALESCE(p_label, p_project);
  v_iri   text := format('urn:ckp:%s/kernel/ck', p_project);
  v_g     int;
  v_ttl   text;
  v_base  text := format('urn:ckp:%s', p_project);
  v_kid   text := format('urn:ckp:%s/kernel', p_project);
  v_pid   text := format('urn:ckp:project:%s', p_project);
  v_prior text;
  v_seeded boolean;
BEGIN
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'project required', 'sqlstate', '22004');
  END IF;
  -- The transport segment is one NATS token. A dotted name can never be granted
  -- (configured_kernels drops it), so germinating one would build a kernel nobody
  -- can ever reach. Refuse at the door with the slug it should use.
  -- p_project is ONE transport segment, not an IRI. The metacharacter test alone
  -- let ':' and '/' through, so a caller passing the project URN
  -- ('urn:ckp:project:ck-lib-js') germinated a graph named
  -- <urn:ckp:urn:ckp:project:ck-lib-js/kernel/ck> -- structurally valid, and
  -- reachable by nobody. Measured on the bench: 22 asserted triples in exactly
  -- that graph. Require a bare segment; the metacharacter case keeps its own
  -- message because the slug is actionable there.
  IF p_project ~ '[.*> \t\r\n]' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'sqlstate', '22023', 'error', format('kernel id %L carries a NATS subject metacharacter, so it can never be granted. Use %L.',
                      p_project, ckp._slug(p_project)));
  END IF;
  IF p_project !~ '^[a-z0-9]+(-[a-z0-9]+)*$' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'sqlstate', '22023', 'error', format('kernel id %L is not canonical. A project name is lowercase, dashes optional, one transport segment -- use %L.',
                      p_project, ckp._slug(regexp_replace(p_project, '^.*[:/]', ''))));
  END IF;
  -- IDENTITY IS SERVER-DERIVED. No verified connection, no owner, no germination —
  -- fail closed rather than mint an unowned project or invent an owner.
  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'sqlstate', '42501', 'error', 'germination requires a verified identity: ckp.ownedBy is stamped from the connection, never supplied. Anonymous callers cannot own a project.');
  END IF;
  v_owner := 'urn:ckp:participant:' || ckp._slug(v_sub);

  -- 0.4.89 (F-TAKEOVER, finding-1788052032938005000): germination CLEARS the kernel
  -- graph and re-stamps ownedBy, and until now nothing refused a SECOND germination
  -- of a project someone else owns. Every verified identity holds publish on every
  -- ROSTERED segment (auth_callout::permissions_for mints input.kernel.<k>.id.<own
  -- sub>.action.> per roster entry, measured), so any bot on a shared door could
  -- wipe a live kernel's graph and stamp itself as its owner. The act was always
  -- ATTRIBUTED — the four stamps never lie — but attribution is a record, not a
  -- refusal, and a destructive act must be refused. It also blocked the bootstrap
  -- cure for finding-1788051883233705000: a self-grant on your own segment is only
  -- safe once re-germination is gated, or the hazard goes from bounded to open.
  --
  -- Ownership lives on the sealed ckp:Project (ckp:ownedBy); existence is the sealed
  -- ckp:Kernel. FAIL CLOSED on the destructive path: an existing kernel whose owner
  -- this ledger cannot name refuses too, rather than being clearable by anyone.
  SELECT i.body->>'https://conceptkernel.org/ontology/v3.11/core#ownedBy' INTO v_prior
    FROM ckp.instances i
   WHERE i.body->>'@id' = v_pid
     AND i.body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Project'
   ORDER BY i.ts_created DESC LIMIT 1;
  SELECT EXISTS(SELECT 1 FROM ckp.instances i
                 WHERE i.body->>'@id' = v_kid
                   AND i.body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Kernel')
    INTO v_seeded;
  IF v_seeded AND COALESCE(v_prior, '') IS DISTINCT FROM v_owner THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'sqlstate', '42501',
      'error', format('kernel %L is already germinated and owned by %s. Germination CLEARS the kernel graph, so re-germinating a kernel you do not own is refused -- ask its owner, or germinate a name you own.',
                      p_project, COALESCE(v_prior, 'an owner this ledger cannot name')));
  END IF;

  -- 1. the structure — Kernel + three organs, counted dependencies, gated authorities.
  -- 0.4.104 (C-13): the epoch stamp follows the LOADED law — ckp:epoch where the
  -- loaded KernelShape still forces it (an upgraded door whose core predates the
  -- rename), germinatedAtEpoch where the revised law is loaded. Emitting against
  -- the other door's law is a MinCount refusal — the 0.4.88 G-1 defect class.
  v_law_epoch := ckp._law_forces_kernel_epoch();
  v_g := pgrdf.add_graph(v_iri);
  PERFORM pgrdf.clear_graph(v_g);
  v_ttl := format($ttl$
@prefix ckp:  <https://conceptkernel.org/ontology/v3.11/core#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
<%1$s/kernel> a ckp:Kernel ; rdfs:label %2$L ; %4$s 0 ;
  ckp:inProject <%3$s> ;
  ckp:hasOrgan <%1$s/organ/ck> , <%1$s/organ/tool> , <%1$s/organ/data> .
<%1$s/organ/ck>   a ckp:Organ , ckp:CK   ; ckp:organKind "ck"   ; ckp:writeAuthority "governed-only" .
<%1$s/organ/tool> a ckp:Organ , ckp:TOOL ; ckp:organKind "tool" ; ckp:writeAuthority "readonly-on-ontology" ;
  ckp:dependsOn <%1$s/organ/ck> .
<%1$s/organ/data> a ckp:Organ , ckp:DATA ; ckp:organKind "data" ; ckp:writeAuthority "readwrite" ;
  ckp:dependsOn <%1$s/organ/ck> , <%1$s/organ/tool> .
$ttl$, v_base, v_label, v_pid,
    CASE WHEN v_law_epoch THEN 'ckp:epoch' ELSE 'ckp:germinatedAtEpoch' END);
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, v_iri || '#');
  PERFORM pgrdf.materialize(v_g);
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;

  -- 0.4.90 (§2): seed the epoch ledger at germination so the row EXISTS from the
  -- kernel's first moment. Both planes then read a real 0 rather than each
  -- rendering an absent row by its own convention.
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_project, 0)
    ON CONFLICT (kernel) DO NOTHING;

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
    CASE WHEN v_law_epoch THEN 'https://conceptkernel.org/ontology/v3.11/core#epoch'
         ELSE 'https://conceptkernel.org/ontology/v3.11/core#germinatedAtEpoch' END, 0,
    'https://conceptkernel.org/ontology/v3.11/core#inProject', v_pid,
    -- 0.4.88 (G-1): the wire form is the SUBSTRATE's, derived from the id the caller
    -- already named and this function already validated at the canonical guard above.
    -- KernelShape gained transportSegment with minCount 1 in root 97f97cb2…; this
    -- emitter did not move with it, so germination refused itself on every door
    -- carrying that root — MinCountConstraintComponent, value null, fleet-wide.
    -- Not caller-supplied ON PURPOSE: a payload-supplied segment is one more place
    -- two names could disagree, and the caller has already said which project it means.
    'https://conceptkernel.org/ontology/v3.11/core#transportSegment', p_project,
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

-- 0.4.83 (B7) — the route body. ckp.dispatch is now a thin wrapper that applies
-- ckp._refusal_envelope on the way out, so the refusal envelope is ONE law at the door
-- instead of 101 hand-built objects. Internal: no role floor grant.
CREATE OR REPLACE FUNCTION ckp._dispatch_route(p_verb text, p_payload jsonb)
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
  v_proj text := ckp._project();
  -- 0.4.80 — NO MANUFACTURED KEY. This COALESCE substituted the literal
  -- 'pgck-localhost' whenever nothing was configured, so absence produced a
  -- shared secret instead of a refusal. The key now comes from ckp.config,
  -- minted per install; ckp.seal already refuses when it is missing, and that
  -- refusal is the point.
  v_idk  text := COALESCE(NULLIF(current_setting('ckp.identity_key', true), ''),
                          (SELECT v FROM ckp.config WHERE k = 'identity_key'));
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
  -- Resolve against the CALLING project, not a fixed kernel. This asked
  -- registry_lookup('pgck', ...) for every caller, so a verb registered by any
  -- other kernel was invisible and every non-pgck workspace got
  -- unknown_affordance. It looked correct only because the seed and the
  -- registrars were hard-coded to the same literal -- writer and reader wrong
  -- in the same direction. (smoke-s4 s41: registered under 's41-test',
  -- resolved under 'pgck'.)
  v_aff   := ckp.registry_lookup(v_proj, v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'sqlstate', '42704', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'sqlstate', '0A000', 'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable', 'sqlstate', '55000',
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
  -- 0.4.51: `@type` and a nested `{body:{type}}` route here TOO, so the teaching
  -- refusal is reachable. Without this a caller following JSON-LD habit fell
  -- through to the task.create concretion and was told "kernel and title
  -- required" — an error about a verb it did not call, naming fields it never
  -- heard of. create_typed answers `type_not_readable_here` and names the two
  -- shapes that ARE read. Routing on a key it will then refuse is deliberate:
  -- the alternative is a correct-looking error from the wrong handler, which is
  -- the class of misdirection F9 filed.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type' OR p_payload ? '@type'
             OR (p_payload ? 'body' AND ((p_payload->'body') ? 'type' OR (p_payload->'body') ? '@type')))
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

  -- 0.4.51 — THE CHECKER SURFACE. Every one of these answered a question this
  -- kernel had to answer with a hand-written psql probe in PASS-30, which is a
  -- second surface by definition: a check that lives in someone's scratch
  -- directory cannot be re-run by the party who needs it, and it is not a fact.
  -- As governed verbs they are callable by any identity the kernel grants,
  -- their answers are attributable, and the negative control ships WITH the
  -- gate instead of beside it.
  WHEN 'wave.signals' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.signals'),
                    ckp.wave_signals(p_payload));

  -- one-version alias (0.4.63): routes, answers, and says where to go. Removed
  -- next release — nothing tagged ever carried the old name.
  WHEN 'wave.oracle' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.oracle'),
                    ckp.wave_signals(p_payload))
        || jsonb_build_object('deprecated', 'wave.oracle is wave.signals; this alias is removed next release');

  WHEN 'adoption.check' THEN
    res := ckp.adoption_check(p_payload);

  WHEN 'wave.project' THEN
    res := COALESCE(ckp._module_gate(v_proj, 'urn:ckp:module:wave', 'wave.project'),
                    ckp.wave_project_spine(p_payload));

  WHEN 'surface.typecheck' THEN
    res := ckp.surface_typecheck(p_payload, v_proj);

  WHEN 'surface.unshaped' THEN
    res := ckp.surface_unshaped(v_proj);

  -- 0.4.83 (B7) — the refusal registry is itself learnable through the door
  -- (a check that is not a verb does not exist): the closed set of refusal
  -- codes, their typed sqlstate classes, and what each teaches.
  WHEN 'surface.refusals' THEN
    -- 0.4.90 (Q-2 + Q-3, CK.Lib.Js). registryDigest is sha256 over the ORDERED
    -- code set, so a client caches on the digest and re-reads only when the set
    -- actually moves. plane rides per row and is NULL where the classification
    -- would be a guess (see the registry table comment).
    -- NOTE: jsonb_strip_nulls is deliberately NOT applied to plane — a stripped
    -- key and an explicit null are different answers, and "we did not classify
    -- this one" must survive the wire. Only `teaches` is stripped when absent.
    res := jsonb_build_object('ok', true,
      'count', (SELECT count(*) FROM ckp.refusal_registry),
      'registryDigest', (SELECT encode(digest(string_agg(code, E'\n' ORDER BY code), 'sha256'), 'hex')
                           FROM ckp.refusal_registry),
      'planes', (SELECT jsonb_object_agg(k, c) FROM (
                   SELECT COALESCE(plane,'unclassified') k, count(*) c
                     FROM ckp.refusal_registry GROUP BY 1) t),
      'refusals', COALESCE((SELECT jsonb_agg(
                    jsonb_strip_nulls(jsonb_build_object(
                      'code', code, 'sqlstate', sqlstate, 'teaches', teaches))
                    || jsonb_build_object('plane', plane)
                    ORDER BY sqlstate, code)
                  FROM ckp.refusal_registry), '[]'::jsonb),
      'note', 'an ok:false whose error is not in this set is fault-shaped, not a refusal. '
              'plane:null means the classification would be a guess — 22023 and 42704 each '
              'carry codes of both planes; cache on registryDigest, not on count.');

  WHEN 'surface.declared' THEN
    res := ckp.surface_declared(p_payload, v_proj);

  WHEN 'surface.grounding' THEN
    res := ckp.surface_grounding(p_payload, v_proj);

  WHEN 'surface.explain' THEN
    res := ckp.surface_explain(p_payload, v_proj);

  WHEN 'fleet.adoptions' THEN
    res := ckp.fleet_adoptions(p_payload);

  WHEN 'project.resolve' THEN
    res := ckp.project_resolve(p_payload);

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
    res := res || ckp._read_verdict(jsonb_array_length(res->'kernels'));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      -- 0.4.66: proofs are PLURAL since obligations (0.4.65). `proof` stays the
      -- byte-proof (the hmac row — what `verified` checks) so existing readers
      -- keep their meaning; `proofs` carries EVERY row, obligations included —
      -- "which agreed checks did this seal pass" must be readable at the door,
      -- or the obligation mark exists only for parties with table access.
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid AND method='hmac+sha256' ORDER BY id DESC LIMIT 1),
        'proofs', COALESCE((SELECT jsonb_agg(jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) ORDER BY id) FROM ckp.proof WHERE about=tid),'[]'::jsonb),
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
             p_payload->>'projectKind');

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
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(tid);
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
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(tid);
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
  -- 0.4.51 — THE EDGE CLASS IS THE CALLER'S TO NAME, AND WAS A DEFAULT NOTHING
  -- DECLARED. This sealed N||'Edge' = urn:ckp:board/Edge unconditionally. That
  -- class is declared in ONE file, examples/example.kernel.ttl, which no module
  -- can load (import_module knows {task, goal}), so the path COULD NOT SEAL FOR
  -- ANY PARTICIPANT ON ANY KERNEL SURFACE, regardless of grants — measured by
  -- pgCK.MCP as F6 and re-measured here: SELECT ?g ?p WHERE { GRAPH ?g { ?s ?p
  -- <urn:ckp:board/Edge> } } returns ZERO ROWS fleet-wide.
  --
  -- Worse, 0.4.42's own comment in ckp._type_admitted asserted the exit
  -- condition was met — "urn:ckp:board/{Task,Goal,Edge,Message} now carry shapes
  -- in the project kernel graph". They do not. That sentence is deleted with
  -- this default; a comment claiming a gate is a claim, and R1 applies to
  -- claims about our own code exactly as it applies to shapes.
  --
  -- The kernel declares what an edge IS; the substrate refuses what violates
  -- that. So the class comes from the caller and the property IRIs follow ITS
  -- namespace — the same rule create_typed's fallback already uses. A caller
  -- that names no class is REFUSED with the reason, never sealed under a class
  -- nobody declared.
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_etype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_ens   text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF v_etype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','edge_type_required',
          'hint','instance.link requires {type}: the edge class THIS kernel declares (sh:targetClass or a declared rdfs:Class/owl:Class in its composed surface). There is no substrate default — the former one, urn:ckp:board/Edge, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_etype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','instance.link {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Edge');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        v_ens := regexp_replace(v_etype, '[^/#]*$', '');    -- the declared class's namespace
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', v_etype, '@id', 'ckp://Edge#'||eid,
          v_ens||'source', src, v_ens||'predicate', pred, v_ens||'target', tgt, v_ens||'topic', topic,
          v_ens||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'type',v_etype,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj)) || ckp._stamped(eid);
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  -- 0.4.51 — the SAME defect as edge.create, one class along, and untested by
  -- the party who found the first: this sealed N||'Message' = urn:ckp:board/
  -- Message, declared by no loadable module, so notify could not seal either.
  -- The class is the caller's to name; the property IRIs follow its namespace.
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := p_payload->>'predicate';
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
            v_mtype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_mns   text;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSIF v_mtype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','message_type_required',
          'hint','notify requires {type}: the message class THIS kernel declares. There is no substrate default — the former one, urn:ckp:board/Message, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_mtype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','notify {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Message');
      ELSE
        v_mns := regexp_replace(v_mtype, '[^/#]*$', '');
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', v_mtype, '@id', 'ckp://Message#'||mid,
          v_mns||'from', frm, v_mns||'to', tgt, v_mns||'predicate', pred, v_mns||'body', bdy, v_mns||'topic', topic,
          v_mns||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(v_mns||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'type',v_mtype,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1))
          || ckp._stamped(mid);
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'sqlstate', '0A000', 'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.plan_exec(p_kernel text, p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_epoch  integer;
  v_plan   jsonb;
  v_stmt   text;
  v_wrap   text;
  v_np     integer;
  a1       text;
  a2       text;
  v_result jsonb;
BEGIN
  SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = p_kernel;
  v_epoch := COALESCE(v_epoch, 1);
  SELECT plan INTO v_plan FROM ckp.plans WHERE kernel = p_kernel AND verb = p_verb AND epoch = v_epoch;
  IF v_plan IS NULL THEN
    -- CI-C-2: a missing plan at the current epoch forces recompile-then-retry inside the call.
    PERFORM ckp.compile_plans(p_kernel);
    SELECT plan INTO v_plan FROM ckp.plans WHERE kernel = p_kernel AND verb = p_verb AND epoch = v_epoch;
  END IF;
  IF v_plan IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_plan', 'sqlstate', '42704', 'verb', p_verb, 'epoch', v_epoch);
  END IF;
  v_stmt := v_plan->>'statement';
  v_wrap := format('SELECT jsonb_agg(t) FROM (%s) t', v_stmt);
  v_np   := COALESCE(jsonb_array_length(v_plan->'params'), 0);
  -- caller VALUES only, in the plan's declared param order — bound, never concatenated.
  IF v_np >= 1 THEN a1 := p_payload->>(v_plan->'params'->>0); END IF;
  IF v_np >= 2 THEN a2 := p_payload->>(v_plan->'params'->>1); END IF;
  IF    v_np = 0 THEN EXECUTE v_wrap INTO v_result;
  ELSIF v_np = 1 THEN EXECUTE v_wrap INTO v_result USING a1;
  ELSIF v_np = 2 THEN EXECUTE v_wrap INTO v_result USING a1, a2;
  ELSE  RAISE EXCEPTION 'plan_exec: > 2 bound params not supported yet (verb %, np %)', p_verb, v_np;
  END IF;
  RETURN jsonb_build_object('ok', true, 'verb', p_verb, 'epoch', v_epoch,
                            'rows', COALESCE(v_result, '[]'::jsonb));
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
  -- P0-E (pgCK#28): NO GOVERNED OP WITHOUT A PROJECTOR. An op that cannot
  -- project a change is refused HERE, at propose — never sealed as an inert
  -- "applied" that bumps the epoch and changes nothing. These four have a
  -- projector today: add_class / add_property / set_transition_map translate
  -- via ckp._op_to_ttl; add_affordance registers a query/derived plan at apply.
  -- modify_shape_constraint / set_quorum / set_materialize_policy have none yet
  -- (they would seal and do nothing) — refused until a projector exists,
  -- default-deny per I2. Widening this set requires implementing the projector,
  -- not editing the list. 0.4.65 adds add_proof_obligation (§5b): its projector
  -- is ckp.register_proof_obligation at apply — the obligation registry is the
  -- change it projects, the seal-exit dual of add_affordance's dispatch entry.
  -- 0.4.95 (C-4) — set_kernel_policy joins the closed op set. The law declares
  -- seven Kernel policy properties (weights, decay, thresholds) and states that
  -- each is "an OVERRIDE, sealed only through propose->vote->apply". No projector
  -- could write a Kernel property, so the route the law mandates did not exist and
  -- all seven were unreachable. This is that route.
  v_ops    text[] := ARRAY['add_class','add_property','set_transition_map','add_affordance','add_proof_obligation','set_kernel_policy'];
  v_op     text := p_payload->>'op';
  -- ckp.dispatch calls this with v_proj -- the bare project SEGMENT ('pgck'),
  -- not a URN, despite the parameter name. Defaulting `about` to it produced a
  -- literal where ProposalShape demands sh:IRI, so EVERY proposal that omitted
  -- `about` was refused. Build the kernel IRI when a bare segment arrives.
  v_about  text := COALESCE(p_payload->>'about',
                            CASE WHEN position(':' in p_kernel_urn) > 0 THEN p_kernel_urn
                                 ELSE 'urn:ckp:'||p_kernel_urn||'/kernel/ck' END);
  v_detail jsonb;
  v_quorum int;
  v_pid    text;
  v_body   jsonb;
  v_ttl    text;
  v_report jsonb;
BEGIN
  -- 1. INJECTION-SAFE FIELD GATE (mirrors ProposalShape; makes step 2's TTL construction safe).
  -- P0-E, SECOND HALF. That the OP has a projector is not enough: the DETAIL must
  -- carry something to project. add_affordance with an empty detail sealed as
  -- `applied`, bumped the epoch, registered nothing, and returned ok:true with
  -- graph_changed:false and no error anywhere -- measured on pgck, epoch 5 is
  -- exactly that inert applied. Refuse at propose, which is what P0-E promised.
  IF v_op = 'add_affordance' THEN
    v_detail := COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb);
    IF NOT (v_detail ? 'verb') OR NOT (v_detail ? 'query') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'sqlstate', '22023', 'op', v_op,
        'hint', 'add_affordance needs detail.verb and detail.query; without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  -- add_proof_obligation, same P0-E half: an activation must name the obligation,
  -- its target type AND a check from the fixed registry; a deactivation
  -- ({active:false}) needs only the obligation name. The strict parse (IRI
  -- shape, check-in-registry) lives in ckp.register_proof_obligation — refused
  -- again at apply if it fails there; this gate refuses the detail that could
  -- not project anything at all.
  IF v_op = 'add_proof_obligation' THEN
    v_detail := COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb);
    IF NOT (v_detail ? 'obligation')
       OR (COALESCE(v_detail->>'active','true') <> 'false'
           AND (NOT (v_detail ? 'targetType') OR NOT (v_detail ? 'check'))) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'sqlstate', '22023', 'op', v_op,
        'hint', 'add_proof_obligation needs detail.obligation + detail.targetType + detail.check (or detail.obligation + active:false to deactivate); without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_has_no_projector', 'sqlstate', '22023', 'op', v_op,
                              'hint', 'a governed op is refused at propose unless it can project a change (P0-E, pgCK#28)',
                              'allowed', to_jsonb(v_ops));
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
  END IF;
  BEGIN
    v_quorum := COALESCE((p_payload->>'requires_quorum')::int, 1);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'sqlstate', '22023',
                              'value', p_payload->>'requires_quorum');
  END;
  -- 0.4.98 (C-1 / L-8): a project that declared `shared` cannot then propose a
  -- change it may approve alone. The refusal names the clause and the cure, and
  -- points at the declaration rather than at a policy nobody can read.
  IF v_quorum < ckp._quorum_floor(p_kernel_urn) THEN
    RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '55000',
      'error', 'invalid_requires_quorum',
      'value', v_quorum,
      'floor', ckp._quorum_floor(p_kernel_urn),
      'hint', format('this project seals ckp:projectKind "shared", whose declared meaning is '
                     '"several members, where governed change clears a quorum". A quorum of %s '
                     'would let the proposer approve its own change. Propose at %s or higher, or '
                     'govern the project to "personal" first — that is a decision with a record, '
                     'which is the point.', v_quorum, ckp._quorum_floor(p_kernel_urn)));
  END IF;
  IF v_quorum < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'sqlstate', '22023', 'value', v_quorum);
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
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'sqlstate', '23514', 'violations', v_report->'violations');
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
    -- accept BOTH spellings: the door historically took 'detail' while the
    -- sealed key is 'proposalDetail', so a caller using the name it reads back
    -- silently got {}.
    'proposalDetail',    COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb)
  );
  PERFORM ckp.seal(v_pid, v_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_pid, 'proposal_iri', 'ckp://Proposal#'||v_pid,
                            'state', 'pending', 'op', v_op, 'verified', ckp.verify(v_pid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.query(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := ckp._project();
  v_ops     jsonb := '{"eq":"=","neq":"<>","lt":"<","lte":"<=","gt":">","gte":">=","contains":"LIKE"}'::jsonb;
  v_key_re  text := '^[A-Za-z][A-Za-z0-9:#/._-]*$';   -- the unshaped-fallback key gate
  v_propmap jsonb;          -- declared localname -> full path IRI ({} when the type is unshaped)
  v_shaped  boolean;
  v_where   text;
  v_limit   int := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 100), 1), 1000);
  v_offset  int := GREATEST(COALESCE((p_payload->>'offset')::int, 0), 0);
  f         jsonb;
  v_op text; v_key_in text; v_key text; v_val text;
  v_sql text; v_result jsonb;
BEGIN
  IF v_type IS NULL OR v_type !~ '^[A-Za-z]' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type', 'sqlstate', '22023', 'type', v_type);
  END IF;

  -- Derive the type's declared property map. 0.4.51: one definition
  -- (ckp._propmap), and this is the ONE declared exception to it — p_composed
  -- false keeps the kernel-graph read, because v_shaped below turns the map
  -- into a REFUSAL set for filter keys. Widening it here would newly refuse
  -- reads that resolve today against substrate-stamped keys no shape declares.
  -- Held as a named argument with a reason rather than tightened silently.
  v_propmap := ckp._propmap(v_type, v_proj, false);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_where := format('(body->>%L) = %L', 'type', v_type);   -- base: this instance type only

  FOR f IN SELECT jsonb_array_elements(COALESCE(p_payload->'filter', '[]'::jsonb)) LOOP
    v_op := f->>'op'; v_key_in := f->>'key'; v_val := f->>'value';
    IF NOT (v_ops ? v_op) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_operator', 'sqlstate', '22023', 'op', v_op,
                                'allowed', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_ops) k));
    END IF;

    -- KEY RESOLUTION.
    IF v_shaped THEN
      -- shaped type: the key MUST be a declared property (by localname or full IRI).
      IF v_propmap ? v_key_in THEN
        v_key := v_propmap->>v_key_in;                                   -- declared localname -> IRI
      ELSIF v_key_in IS NOT NULL
            AND EXISTS (SELECT 1 FROM jsonb_each_text(v_propmap) e WHERE e.value = v_key_in) THEN
        v_key := v_key_in;                                              -- already a declared full IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_filter_key', 'sqlstate', '42704',
                                  'key', v_key_in, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      -- unshaped for THIS session's project (the shape isn't in urn:ckp:<project>/kernel/ck, or
      -- the type is genuinely unshaped). Resolve the key against the ACTUAL instance-body keys —
      -- exact full-IRI OR by localname suffix — so the filter runs against the key the bodies use,
      -- independent of the shape/project read (pgCK#6). Bare-key bodies (localname == key) resolve
      -- to themselves, so s29 back-compat holds.
      IF v_key_in IS NULL OR v_key_in !~ v_key_re THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'sqlstate', '22023', 'key', v_key_in);
      END IF;
      SELECT bk INTO v_key
      FROM ckp.instances i
      CROSS JOIN LATERAL jsonb_object_keys(i.body) AS bk
      WHERE i.body->>'type' = v_type
        AND (bk = v_key_in OR regexp_replace(bk, '^.*[/#]', '') = v_key_in)
      LIMIT 1;
      IF v_key IS NULL THEN
        -- NEVER a silent [] (pgCK#6): the key maps to no stored property on this type.
        IF EXISTS (SELECT 1 FROM ckp.instances WHERE body->>'type' = v_type) THEN
          RETURN jsonb_build_object('ok', false, 'error', 'unresolved_shape', 'sqlstate', '42704',
                                    'key', v_key_in, 'type', v_type,
                                    'hint', 'no shape for this type in the session project and no instance carries this property key');
        END IF;
        v_key := v_key_in;   -- no instances of this type: the filtered read is legitimately empty
      END IF;
    END IF;

    -- WHERE construction (unchanged operator logic; quote_literal values + enum operators).
    IF v_op = 'contains' THEN
      v_where := v_where || format(' AND (body->>%L) LIKE %L', v_key, '%'||COALESCE(v_val,'')||'%');
    ELSIF v_op IN ('lt','lte','gt','gte') THEN
      IF v_val IS NULL OR v_val !~ '^-?[0-9.]+$' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_numeric_value', 'sqlstate', '22023', 'op', v_op, 'value', v_val);
      END IF;
      v_where := v_where || format(' AND (body->>%L) ~ ''^-?[0-9.]+$'' AND (body->>%L)::numeric %s %s',
                                   v_key, v_key, v_ops->>v_op, v_val);
    ELSE  -- eq, neq
      v_where := v_where || format(' AND (body->>%L) %s %L', v_key, v_ops->>v_op, v_val);
    END IF;
  END LOOP;

  v_sql := format(
    'SELECT jsonb_agg(jsonb_build_object(''id'', id, ''body'', body) ORDER BY id) '
    'FROM (SELECT id, body FROM ckp.instances WHERE %s ORDER BY id LIMIT %s OFFSET %s) t',
    v_where, v_limit, v_offset);
  EXECUTE v_sql INTO v_result;
  RETURN jsonb_build_object('ok', true, 'type', v_type, 'shaped', v_shaped,
                            'count', COALESCE(jsonb_array_length(v_result), 0),
                            'rows', COALESCE(v_result, '[]'::jsonb))
         || ckp._read_verdict(COALESCE(jsonb_array_length(v_result), 0), v_limit);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.reach(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_from     text := p_payload->>'from';
  v_from_iri text;
  v_via      text := p_payload->>'via';
  v_proj     text := ckp._project();
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_max      int  := COALESCE(NULLIF(current_setting('pgrdf.path_max_depth', true),'')::int, 0);
  v_declared jsonb;
  v_reached  jsonb;
BEGIN
  IF v_from IS NULL OR btrim(v_from) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'sqlstate', '22023', 'from', v_from);
  END IF;
  -- id-form: a bare instance id resolves to its @id IRI (the form link/materialize_edge wrote);
  -- an absolute IRI passes through. An unresolvable bare id has nothing to reach FROM.
  v_from_iri := ckp._resolve_ref(v_from);
  IF v_from_iri IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'from', v_from, 'resolved', NULL, 'via', v_via,
                              'max_depth', v_max, 'reached', '[]'::jsonb);
  END IF;
  IF v_from_iri !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'sqlstate', '22023', 'from', v_from, 'resolved', v_from_iri);
  END IF;
  -- injection-safe IRI gate on `via` (always).
  IF v_via IS NULL OR v_via !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'sqlstate', '42704', 'via', v_via);
  END IF;
  -- T2: `via` MUST be in the kernel's DECLARED predicate set; a kernel that declares none falls
  -- back to the namespace allowlist (back-compat).
  v_declared := ckp.declared_predicates(v_proj);
  IF jsonb_array_length(v_declared) > 0 THEN
    IF NOT (v_declared @> to_jsonb(v_via)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'sqlstate', '42704', 'via', v_via, 'declared', v_declared);
    END IF;
  ELSIF NOT (v_via LIKE 'https://conceptkernel.org/%' OR v_via LIKE 'urn:ckp:%') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'sqlstate', '42704', 'via', v_via);
  END IF;
  -- bounded transitive traversal over the materialized link quads — `+` engine-capped.
  SELECT jsonb_agg(DISTINCT j->>'r') INTO v_reached
  FROM pgrdf.sparql(format('SELECT ?r WHERE { GRAPH ?g { <%s> <%s>+ ?r } }', v_from_iri, v_via)) j;
  RETURN jsonb_build_object('ok', true, 'from', v_from, 'resolved', v_from_iri, 'via', v_via,
                            'max_depth', v_max, 'reached', COALESCE(v_reached, '[]'::jsonb))
         || ckp._read_verdict(COALESCE(jsonb_array_length(v_reached), 0));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.retire(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_id     text := p_payload->>'id';
  v_reason text := p_payload->>'reason';
  v_proj   text := ckp._project();
  v_epoch  int;
  v_body   jsonb;
  v_type   text;
BEGIN
  IF v_reason IS NULL OR length(btrim(v_reason)) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reason_required', 'sqlstate', '22004', 'id', v_id);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'sqlstate', '42704', 'id', v_id);
  END IF;
  -- Only a DECLARED retirement blocks a second one. A row carrying the bare
  -- pre-0.4.55 `retired` key and no ckp:retiredAtEpoch was never retired in any
  -- way another kernel can read, so letting the sanctioned verb finish the act is
  -- COMPLETING it, not repeating it and not backfilling it — nothing is invented,
  -- the declared property is simply moved to where the private key already said
  -- it was. This is what lets F15's two observed rows close instead of standing
  -- as scars that every reader has to be told about.
  IF v_body ? (C||'retiredAtEpoch') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_retired', 'sqlstate', '55000', 'id', v_id,
      'reason', COALESCE(v_body->>(C||'reason'), v_body->>'retired_reason'));
  END IF;
  -- 0.4.55 — RETIREMENT NOW MOVES THE DECLARED PROPERTY, AND STOPS MINTING KEYS.
  --
  -- This wrote bare `retired` and `retired_reason` — not IRIs at all, so they
  -- entered the body as undeclared predicates, which is the E3/R2 fail-open this
  -- substrate exists to end, committed by the retraction path itself. Worse, the
  -- DECLARED state never moved: a retired Proposal kept ckp:proposalState
  -- "pending" forever, so every other kernel reading the gated property saw
  -- outstanding work that no longer existed.
  --
  -- pgCK.MCP found it from outside and filed it as F15, and its reasoning is the
  -- correct one: it counted those proposals as pending "because the declared
  -- property is the only one another kernel can rely on". A retraction that only
  -- a private key records is not a retraction — it is a note.
  --
  -- Declared vocabulary only, from here:
  --   ckp:retiredAtEpoch  integer, already honoured by ckp.affordances_of
  --   ckp:reason          string, the same property FailedMaterialization carries
  --   ckp:proposalState   for a Proposal, moved to 'rejected' — the enum is
  --                       (pending applied rejected) and it is sh:in-GATED, so if
  --                       this value were wrong the seal would refuse and say so.
  --
  -- The retraction stays a sealed fact: body' carries it, the seal appends ledger
  -- + proof, every prior body stays in the chain. Nothing is ever unsealed.
  v_epoch := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
  v_type  := v_body->>'type';
  v_body  := v_body || jsonb_build_object(
               C||'retiredAtEpoch', to_jsonb(v_epoch),
               C||'reason', btrim(v_reason));
  IF v_type = C||'Proposal' THEN
    v_body := v_body || jsonb_build_object(C||'proposalState', 'rejected');
  END IF;
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id,
    'retiredAtEpoch', v_epoch,
    'declaredStateMoved', (v_type = C||'Proposal'),
    'reason', btrim(v_reason), 'verified', ckp.verify(v_id)) || ckp._stamped(v_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.run_derived_affordance(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- The plan is keyed by (kernel, verb, epoch). Reading it under a hard-coded
  -- kernel while register_*_affordance writes under p_project splits the pair:
  -- the write lands under the calling project and the read never finds it.
  -- Both sides now resolve the SAME way dispatch does.
  v_proj   text := ckp._project();
  v_plan    jsonb;
  v_epoch   bigint;
  v_formula text;
  v_scope   jsonb;
  v_concept text := p_payload->>'concept';
  v_val_re  text := '^[A-Za-z0-9 ._:#/-]*$';   -- concept VALUE gate (no quote/brace/backslash)
  v_res     jsonb;
  wm_now    bigint;
  wm_ph     bigint;
BEGIN
  SELECT plan, epoch INTO v_plan, v_epoch FROM ckp.plans
    WHERE kernel IN (v_proj, 'pgck') AND verb = p_verb
   ORDER BY (kernel = v_proj) DESC, epoch DESC LIMIT 1;
  IF v_plan IS NULL OR v_plan->>'kind' <> 'derived' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_derived_affordance', 'sqlstate', '42704', 'verb', p_verb); END IF;
  IF v_concept IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'sqlstate', '22004', 'param', 'concept'); END IF;
  IF v_concept !~ v_val_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'sqlstate', '22023', 'param', 'concept'); END IF;

  v_formula := v_plan->>'formula';
  v_scope   := (v_plan->'scope') || jsonb_build_object('about', v_concept);   -- bind the concept

  v_res  := ckp.derived_sum(v_concept, v_scope, v_formula, v_epoch);
  wm_now := ckp._source_watermark(v_scope);
  SELECT watermark INTO wm_ph FROM ckp.phenotype_ptr WHERE concept = v_concept;

  RETURN jsonb_build_object(
    'ok', true, 'verb', p_verb,
    'value', (v_res->>'value')::numeric,
    'scored', true,
    'freshness', jsonb_build_object('watermark', wm_ph, 'current', wm_now,
                                    'fresh', COALESCE(wm_ph >= wm_now, false)));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.run_query_affordance(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- The plan is keyed by (kernel, verb, epoch). Reading it under a hard-coded
  -- kernel while register_*_affordance writes under p_project splits the pair:
  -- the write lands under the calling project and the read never finds it.
  -- Both sides now resolve the SAME way dispatch does.
  v_proj   text := ckp._project();
  v_plan   jsonb;
  v_stmt   text;
  v_params jsonb;
  v_val_re text := '^[A-Za-z0-9 ._:#/-]*$';   -- param VALUE gate: no quote/brace/backslash/?-var
  v_name   text;
  v_val    text;
  v_rows   jsonb;
BEGIN
  -- latest-epoch plan for this governed verb (a stale epoch is simply superseded).
  -- PLAN RESOLUTION = your own first, then the substrate floor. A plan the
  -- calling project registered wins; otherwise fall back to the one seeded at
  -- install, which belongs to no kernel because install runs before any kernel
  -- exists. Reading ONLY the floor made every project share one kernel's plans;
  -- reading ONLY v_proj made the seeded substrate verbs unreachable for
  -- everyone (smoke-s4 s32). Both halves are needed until the seed itself stops
  -- naming a kernel.
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel IN (v_proj, 'pgck') AND verb = p_verb
   ORDER BY (kernel = v_proj) DESC, epoch DESC LIMIT 1;
  IF v_plan IS NULL OR v_plan->>'kind' <> 'sparql' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_query_affordance', 'sqlstate', '42704', 'verb', p_verb); END IF;

  v_stmt   := v_plan->>'statement';
  v_params := COALESCE(v_plan->'params', '[]'::jsonb);

  -- bind each declared param: the caller supplies a VALUE only; validate it, then substitute
  -- into the author's `$name$` placeholder (placed in string-literal positions by the query).
  FOR v_name IN SELECT jsonb_array_elements_text(v_params) LOOP
    v_val := p_payload->>v_name;
    IF v_val IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'sqlstate', '22004', 'param', v_name); END IF;
    IF v_val !~ v_val_re THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'sqlstate', '22023', 'param', v_name); END IF;
    v_stmt := replace(v_stmt, '$' || v_name || '$', v_val);
  END LOOP;

  -- run the GOVERNED query — the text is a sealed kernel fact; only validated values were bound.
  SELECT jsonb_agg(j) INTO v_rows FROM pgrdf.sparql(v_stmt) j;
  RETURN jsonb_build_object('ok', true, 'verb', p_verb,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'rows', COALESCE(v_rows, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.set_materialize_policy(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_trigger text := p_payload->>'trigger';
  v_profile text := p_payload->>'profile';
BEGIN
  IF v_trigger IS NULL OR v_trigger NOT IN ('batch','on_seal','governance-manual') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_trigger', 'sqlstate', '22023', 'trigger', v_trigger);
  END IF;
  IF v_profile IS NULL OR v_profile NOT IN ('rdfs','owl-rl') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_profile', 'sqlstate', '22023', 'profile', v_profile);
  END IF;
  INSERT INTO ckp.config(k,v) VALUES ('materialize_trigger', v_trigger) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
  INSERT INTO ckp.config(k,v) VALUES ('materialize_profile', v_profile) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
  RETURN jsonb_build_object('ok', true, 'trigger', v_trigger, 'profile', v_profile);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text)
 RETURNS TABLE(shape_class text, target_class text, present boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_comp_iri text := format('urn:ckp:%s/shapes/composed', p_project);
  v_iri      text;
  v_row      record;
  v_n        int := 0;
BEGIN
  -- Prefer the project's composed surface; fall back to the ε0 core so a
  -- project that has not composed yet is still checked for vacuity.
  v_iri := CASE WHEN pgrdf.graph_id(v_comp_iri) IS NOT NULL
                THEN v_comp_iri ELSE 'urn:ckp:core' END;

  FOR v_row IN
    SELECT j->>'s' AS s, j->>'tc' AS tc
    FROM pgrdf.sparql(format(
      'PREFIX sh: <http://www.w3.org/ns/shacl#>
       PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
       SELECT ?s ?tc FROM <%s>
       WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass ?tc }', v_iri)) j
  LOOP
    shape_class  := v_row.s;
    target_class := v_row.tc;
    present      := true;
    v_n := v_n + 1;
    RETURN NEXT;
  END LOOP;

  IF v_n = 0 THEN
    RAISE EXCEPTION
      'ckp.shapes_self_test: % targets NO class — the surface is VACUOUS. '
      'A validation against it would report conforms:true having evaluated '
      'nothing. Check the ontology mount and that ckp.boot() ran.', v_iri;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION ckp.snapshot(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_req text := p_payload->>'requester'; v_rows jsonb;
BEGIN
  -- F-E: a bulk replay requires an explicit grant on the requester.
  IF v_req IS NULL OR NOT ckp.has_grant(v_req, 'snapshot') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'snapshot_not_granted', 'sqlstate', '42501', 'requester', v_req);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'type', body->>'type') ORDER BY id) INTO v_rows FROM ckp.instances;
  RETURN jsonb_build_object('ok', true, 'requester', v_req,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'instances', COALESCE(v_rows, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.snapshot(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_req text := p_payload->>'requester'; v_rows jsonb;
BEGIN
  -- F-E: a bulk replay requires an explicit grant on the requester.
  IF v_req IS NULL OR NOT ckp.has_grant(v_req, 'snapshot') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'snapshot_not_granted', 'sqlstate', '42501', 'requester', v_req);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'type', body->>'type') ORDER BY id) INTO v_rows FROM ckp.instances;
  RETURN jsonb_build_object('ok', true, 'requester', v_req,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'instances', COALESCE(v_rows, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.stage_ttl(p_ttl text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_iri       text := 'urn:ckp:stage:'||pg_backend_pid();
  v_scratch   int;
  v_quads     bigint;
  v_forbidden jsonb;
BEGIN
  -- 1. STAGE — parse the caller's TTL via the engine into a scratch graph. Never concatenated
  --    into SQL; a malformed payload fails in the parser, not in our code.
  v_scratch := pgrdf.add_graph(v_iri);   -- get-or-create BY IRI (stable id; no fixed-id collision)
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:stage#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'sqlstate', '42601', 'detail', SQLERRM);
  END;

  -- 2. META-FENCE — admit only ontology-meta predicates (rdf/rdfs/owl/sh). Any other predicate
  --    (instance data uses ckp:* data predicates; foreign triples use other namespaces) is a
  --    fence violation. The caller may EXTEND the type ontology, never inject data.
  SELECT jsonb_agg(DISTINCT j->>'p') INTO v_forbidden
  FROM pgrdf.sparql(format($q$
    SELECT ?p WHERE { GRAPH <%s> { ?s ?p ?o }
      FILTER( !STRSTARTS(STR(?p), "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2000/01/rdf-schema#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2002/07/owl#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/ns/shacl#") ) }
  $q$, v_iri)) j;

  PERFORM pgrdf.clear_graph(v_scratch);

  IF v_forbidden IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fence_violation', 'sqlstate', '42501',
                              'forbidden_predicates', v_forbidden, 'staged_quads', v_quads);
  END IF;
  RETURN jsonb_build_object('ok', true, 'staged_quads', v_quads, 'fenced', 'ontology-meta-only');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_declared(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_type text := COALESCE(p_payload->>'type', p_payload->>'@type');
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required', 'sqlstate', '22004',
      'hint', 'surface.declared {"type": "<class IRI>"} — the property contract, so a caller can learn it WITHOUT writing');
  END IF;
  -- 0.4.81 — REFUSE A CURIE INSTEAD OF ANSWERING VACUOUSLY. `ckp:Project` is a
  -- prefixed name, not an IRI; the composed surface holds only absolute IRIs, so
  -- it matched nothing and this verb replied `declared: {}` / `admitted: false`
  -- — a confident answer that the type is unknown, about a type the gate judges
  -- every day. A caller learns a FALSE contract and cannot tell it from a real
  -- absence. An absolute IRI here carries :// or begins urn: ; anything else is
  -- a prefix this substrate never expands.
  IF v_type IS NOT NULL AND v_type NOT LIKE '%://%' AND v_type NOT LIKE 'urn:%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'sqlstate', '22023', 'type', v_type,
      'hint', 'this looks like a prefixed name (CURIE), not an IRI. Nothing expands prefixes here — pass the absolute IRI, e.g. https://conceptkernel.org/ontology/v3.11/core#Project rather than ckp:Project.');
  END IF;
  -- The same map create and validate resolve keys through. A caller reading this
  -- and a caller writing a body cannot disagree, because there is one map.
  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj, 'type', v_type,
    'declared', ckp._propmap(v_type, v_proj),
    'kernelGraphOnly', ckp._propmap(v_type, v_proj, false),
    'note', 'declared = the composed surface ∪ this kernel graph, which is what the gate judges against. kernelGraphOnly is what the create path read before 0.4.51 — a difference between them is a property that WOULD have been minted into the type namespace and refused.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_explain(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_type text := COALESCE(p_payload->>'type', p_payload->>'@type');
  v_comp bigint;
  v_map  jsonb;
  v_props jsonb;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required', 'sqlstate', '22004',
      'hint', 'surface.explain {"type": "<class IRI>"} — the declared contract WITH its teaching prose');
  END IF;
  -- 0.4.81 — REFUSE A CURIE INSTEAD OF ANSWERING VACUOUSLY. `ckp:Project` is a
  -- prefixed name, not an IRI; the composed surface holds only absolute IRIs, so
  -- it matched nothing and this verb replied `declared: {}` / `admitted: false`
  -- — a confident answer that the type is unknown, about a type the gate judges
  -- every day. A caller learns a FALSE contract and cannot tell it from a real
  -- absence. An absolute IRI here carries :// or begins urn: ; anything else is
  -- a prefix this substrate never expands.
  IF v_type IS NOT NULL AND v_type NOT LIKE '%://%' AND v_type NOT LIKE 'urn:%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'sqlstate', '22023', 'type', v_type,
      'hint', 'this looks like a prefixed name (CURIE), not an IRI. Nothing expands prefixes here — pass the absolute IRI, e.g. https://conceptkernel.org/ontology/v3.11/core#Project rather than ckp:Project.');
  END IF;
  v_comp := ckp._composed_shapes(v_proj);
  v_map  := ckp._propmap(v_type, v_proj);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'name', k, 'path', v_map->>k,
           'comment', (SELECT o.lexical_value FROM pgrdf._pgrdf_quads q
                         JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
                         JOIN pgrdf._pgrdf_dictionary p ON p.id = q.predicate_id
                         JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
                        WHERE q.graph_id = v_comp AND NOT q.is_inferred
                          AND s.lexical_value = v_map->>k
                          AND p.lexical_value = 'http://www.w3.org/2000/01/rdf-schema#comment'
                        LIMIT 1)) ORDER BY k), '[]'::jsonb)
    INTO v_props
  FROM jsonb_object_keys(v_map) k;
  RETURN jsonb_build_object('ok', true, 'type', v_type, 'kernel', v_proj,
    'comment', (SELECT o.lexical_value FROM pgrdf._pgrdf_quads q
                  JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
                  JOIN pgrdf._pgrdf_dictionary p ON p.id = q.predicate_id
                  JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
                 WHERE q.graph_id = v_comp AND NOT q.is_inferred
                   AND s.lexical_value = v_type
                   AND p.lexical_value = 'http://www.w3.org/2000/01/rdf-schema#comment'
                 LIMIT 1),
    'properties', v_props,
    'note', 'comments are read from the COMPOSED surface, asserted-only — what the gate judges is what this prose explains. A property with a null comment is declared but untaught; that gap is the module author''s, and now it is visible.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_typecheck(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_type text := COALESCE(p_payload->>'type', p_payload->>'@type');
  v_comp int;
  v_ci   text; v_bi text; v_q text; v_a text;
  v_in_comp bool := false; v_in_board bool := false;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required', 'sqlstate', '22004',
      'hint', 'surface.typecheck {"type": "<class IRI>"} — answers whether THIS kernel admits it, and by which graph');
  END IF;
  -- 0.4.81 — REFUSE A CURIE INSTEAD OF ANSWERING VACUOUSLY. `ckp:Project` is a
  -- prefixed name, not an IRI; the composed surface holds only absolute IRIs, so
  -- it matched nothing and this verb replied `declared: {}` / `admitted: false`
  -- — a confident answer that the type is unknown, about a type the gate judges
  -- every day. A caller learns a FALSE contract and cannot tell it from a real
  -- absence. An absolute IRI here carries :// or begins urn: ; anything else is
  -- a prefix this substrate never expands.
  IF v_type IS NOT NULL AND v_type NOT LIKE '%://%' AND v_type NOT LIKE 'urn:%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'sqlstate', '22023', 'type', v_type,
      'hint', 'this looks like a prefixed name (CURIE), not an IRI. Nothing expands prefixes here — pass the absolute IRI, e.g. https://conceptkernel.org/ontology/v3.11/core#Project rather than ckp:Project.');
  END IF;
  v_comp := ckp._composed_shapes(v_proj);
  v_ci := pgrdf.graph_iri(v_comp);
  v_bi := format('urn:ckp:%s/kernel/board', v_proj);
  v_q  := $q$
    PREFIX sh:   <http://www.w3.org/ns/shacl#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX owl:  <http://www.w3.org/2002/07/owl#>
    ASK WHERE { GRAPH <%1$s> {
      { ?s sh:targetClass <%2$s> } UNION { <%2$s> a rdfs:Class } UNION { <%2$s> a owl:Class }
    } }
  $q$;
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_a
    FROM pgrdf.sparql(format(v_q, v_ci, v_type)) j LIMIT 1;
  v_in_comp := COALESCE(v_a,'false') = 'true';
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_a
    FROM pgrdf.sparql(format(v_q, v_bi, v_type)) j LIMIT 1;
  v_in_board := COALESCE(v_a,'false') = 'true';
  RETURN jsonb_build_object(
    'ok', true,
    'kernel', v_proj,
    'type', v_type,
    -- the gate's OWN answer, not a re-implementation of it
    'admitted', ckp._type_admitted(v_type, v_proj, v_comp),
    'via', CASE WHEN v_in_comp THEN 'composed' WHEN v_in_board THEN 'board' ELSE null END,
    'shaped', (SELECT count(*) > 0 FROM pgrdf.sparql(format(
       'PREFIX sh: <http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <%s> { ?s sh:targetClass <%s> } }',
       v_ci, v_type))),
    'surface', v_ci,
    'surfaceDigest', ckp._surface_digest(v_comp),
    'epoch', COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0),
    -- SHAPED is the half that decides whether a seal is GATED. Admitted-but-
    -- unshaped seals verified:true and conformsToShape ABSENT, which is P13's
    -- "no outcome recorded by omission" happening inside the record.
    'note', 'admitted says the type may seal; shaped says a seal would be JUDGED. Admitted and not shaped means conformsToShape will be absent.');
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
  N        text := 'urn:ckp:board/';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';
  v_body   jsonb; v_from text; v_type text; v_allowed jsonb; v_has_map boolean; v_src text;
BEGIN
  IF v_to IS NULL OR v_to !~ v_state_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'sqlstate', '22023', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'sqlstate', '42704', 'id', v_id);
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
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition', 'sqlstate', '55000',
                                'from', v_from, 'to', v_to, 'source', v_src);
    END IF;
  ELSE
    -- fallback: the global config map (back-compat).
    v_src := 'config';
    v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
    IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition', 'sqlstate', '55000',
                                'from', v_from, 'to', v_to, 'allowed', v_allowed, 'source', v_src);
    END IF;
  END IF;

  v_body := v_body || jsonb_build_object(N||'lifecycle_state', v_to, 'state', v_to);
  -- 0.4.57 — THE RE-SEAL IS JUDGED BY THE KERNEL THAT PRODUCED THE FACT, never
  -- by the ambient session project. This sealed under _project(), so an
  -- instance produced by demo, transitioned from a session whose GUC named a
  -- different kernel, was re-validated against a FOREIGN surface — an M2
  -- violation (jurisdiction: whose meaning governs it). Invisible while the
  -- type gate was fleet-wide; the moment the gate was scoped (0.4.51), s56
  -- refused exactly this, which is that test doing its job one layer deeper
  -- than it was written for. The map lookup above was already
  -- project-independent; the re-seal now follows the same rule: derive the
  -- project from the substrate-stamped producedBy (unforgeable), fall back to
  -- the session only for pre-stamp rows.
  DECLARE
    v_pb   text := v_body->>(C||'producedBy');
    v_proj text;
  BEGIN
    IF v_pb IS NOT NULL AND v_pb ~ '^urn:ckp:.+/kernel/ck$' THEN
      v_proj := regexp_replace(v_pb, '^urn:ckp:(.+)/kernel/ck$', '\1');
      PERFORM set_config('ckp.project', v_proj, true);
    END IF;
    PERFORM ckp.seal(v_id, v_body);
  END;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to,
                            'source', v_src, 'verified', ckp.verify(v_id)) || ckp._stamped(v_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.update_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id      text := p_payload->>'id';
  v_patch   jsonb := p_payload->'patch';
  v_proj    text := ckp._project();
  v_cur     jsonb;
  v_type    text;
  v_ns      text;
  v_propmap jsonb;
  v_shaped  boolean;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_id IS NULL OR btrim(v_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_required', 'sqlstate', '22004'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'sqlstate', '22023', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  -- 0.4.102 (E-5) — ONE ID VOCABULARY, READ AND WRITE ALIKE. instance.get has
  -- resolved bare, ckp://Type#id and urn:ckp:instance:<id> forms since 0.4.90;
  -- this verb kept looking up ckp.instances.id directly, so a caller could READ
  -- a fact by the @id a create reply stamped and could not PATCH it with the
  -- same string — and the refusal said unknown_instance, which points at
  -- existence when the defect was spelling. Same resolver, second caller: a
  -- verb that re-implements the resolver forks the id vocabulary, exactly as a
  -- probe that re-implements the gate tests the probe.
  v_id := ckp._resolve_id(v_id);
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'sqlstate', '42704', 'id', v_id,
      'hint', 'accepted id forms: the bare instance id, the stamped @id (ckp://Type#id), and urn:ckp:instance:<id>'); END IF;

  v_type := v_cur->>'type';
  v_ns   := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;

  -- declared property map for the instance's type (same read as create_typed).
  -- 0.4.51: composed-aware, because a patch is a WRITE and must resolve keys the
  -- same way the gate will judge them. Refusing an undeclared patch key earlier,
  -- with the declared set named, is strictly better than sealing it under the
  -- type's namespace and letting the gate refuse the whole body.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_cur := v_cur - 'participant';   -- re-resolved by ckp.seal from any supplied claims

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    CONTINUE WHEN v_key IN ('id', 'type', '@id');   -- not patchable via this path
    IF position(':' in v_key) > 0 THEN
      -- 0.4.96 (E-3) — BEING AN IRI IS NOT BEING DECLARED.
      -- This branch passed any key containing ':' straight through on the
      -- strength of its FORM. The bare form was checked against the declared
      -- set and refused; the SAME property spelled as a full IRI was accepted.
      -- Measured: patch {'weightNonsense': …} refuses undeclared_patch_key,
      -- patch {'https://…core#weightNonsense': …} lands on the sealed instance.
      -- Nothing downstream catches it either — no shape targets a property that
      -- does not exist, so it conforms VACUOUSLY. That is the exact trap this
      -- composed-aware path was built to close, surviving inside it, and it was
      -- found only because a control that had been passing for the wrong reason
      -- was made to assert the reason.
      --
      -- The check is by VALUE, because _propmap maps localname -> IRI. On an
      -- UNSHAPED type it is deliberately skipped: there is no declared contract
      -- to check against, and refusing would invent one the surface never made.
      IF v_shaped AND NOT EXISTS (
           SELECT 1 FROM jsonb_each_text(v_propmap) m WHERE m.value = v_key) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key', 'sqlstate', '42704',
                                  'key', v_key, 'type', v_type, 'form', 'absolute-iri',
                                  'hint', 'spelling the namespace out does not declare a property',
                                  'declared', (SELECT jsonb_agg(m.value ORDER BY m.value)
                                                 FROM jsonb_each_text(v_propmap) m));
      END IF;
      v_keyiri := v_key;                                    -- declared, in IRI form
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key', 'sqlstate', '42704',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
    END IF;
    -- 0.4.102 (E-4) — "THE TRIPLE A CLIENT CANNOT WRITE", MADE TRUE. The
    -- germinate guard (0.4.89) says who may re-germinate by reading ownedBy;
    -- the apply gate (0.4.99) says who may enact by reading ownedBy. But
    -- ownedBy itself was an ordinary declared property, so ANY party could
    -- rewrite it through this verb and void both gates in one step — measured
    -- on a virgin 0.4.101: a non-owner moved a Project from tdd-e4-owner to
    -- tdd-e4-attacker with a plain instance.update. Ownership is server-derived
    -- at germination and there is NO transfer verb; that absence is a filed
    -- finding, not a licence to patch. The guard sits AFTER key resolution so
    -- every spelling — bare, CURIE, full IRI — meets it (the E-3 lesson).
    IF v_keyiri = 'https://conceptkernel.org/ontology/v3.11/core#ownedBy' THEN
      RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
        'error', 'ownership_not_patchable', 'key', v_keyiri, 'id', v_id,
        'hint', 'ckp:ownedBy is server-derived at germination and no transfer verb exists — '
                'both the germinate guard and the apply gate read this triple, so a patchable '
                'owner voids both. Ownership moves only when a governed transfer verb ships.');
    END IF;
    -- projectKind is the quorum floor (C-1/L-8): a stranger flipping a shared
    -- project to personal drops the floor to 1 and self-approves — the same
    -- takeover as rewriting the owner, one link over. Bind only what declared
    -- itself, exactly as apply's gate does: a declared owner gates the field,
    -- an unowned instance imposes nothing.
    IF v_keyiri = 'https://conceptkernel.org/ontology/v3.11/core#projectKind' THEN
      DECLARE
        v_owner text := v_cur->>'https://conceptkernel.org/ontology/v3.11/core#ownedBy';
        v_me    text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
      BEGIN
        IF v_owner IS NOT NULL THEN
          v_me := CASE WHEN v_me IS NULL THEN NULL
                       ELSE 'urn:ckp:participant:'||ckp._slug(v_me) END;
          IF v_me IS DISTINCT FROM v_owner THEN
            RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
              'error', 'not_owner', 'key', v_keyiri, 'owner', v_owner,
              'hint', 'ckp:projectKind is the quorum floor: only the declared owner may move '
                      'it. An unowned instance imposes nothing — the 0.4.81 rule.');
          END IF;
        END IF;
      END;
    END IF;
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1))
    || ckp._stamped(v_id)
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);
  v_type    text := v_body->>'type';
  v_proj    text := ckp._project();
  v_subj    text := 'urn:ckp:validate:'||pg_backend_pid();
  v_ns      text;
  v_propmap jsonb;
  v_resolved jsonb;
  v_key text; v_val jsonb; v_kiri text;
  v_scratch bigint;
  v_comp    int;
  v_ttl     text;
  v_report  jsonb;
BEGIN
  IF v_type IS NULL THEN
    -- 0.4.51 — the payload IS read as COALESCE(p_payload->'body', p_payload), so
    -- flat {type, …} and nested {body:{type, …}} both work and
    -- {type, body:{…}} is the ONE shape that cannot: the type sits outside the
    -- body this descends into. Saying "type_required" there names the single
    -- field the caller DID supply, and the caller re-sends it. Distinguish.
    IF p_payload ? '@type' OR p_payload ? 'type'
       OR (jsonb_typeof(p_payload->'body') = 'object' AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here', 'sqlstate', '42704',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}}. NOT accepted: @type (never read), or {"type": …, "body": {…}} — that puts the type outside the body this verb descends into.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required', 'sqlstate', '22004',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;

  -- P0-D mechanism 2 parity (pgCK#27): validate PREDICTS seal. seal refuses an
  -- undeclared type before the SHACL gate; validate must report the same, or
  -- validate <=> seal is a slogan. An undeclared type reports conforms=false
  -- with a violation naming it — never the vacuous conforms=true that let
  -- invented types look valid.
  v_comp := ckp._composed_shapes(v_proj);
  BEGIN
    IF NOT ckp._type_admitted(v_type, v_proj, v_comp) THEN
      RETURN jsonb_build_object('ok', true, 'type', v_type, 'conforms', false,
        'violations', jsonb_build_array(jsonb_build_object(
          'focusNode', v_type, 'resultMessage', 'type is not admitted — no shape targets it and it is declared by no class',
          'sourceConstraintComponent', 'ckp:AdmittedTypeConstraint')),
        'report', jsonb_build_object('conforms', false));
    END IF;
  END;

  -- Resolve the body's short keys to declared property IRIs (mirror ckp.create_typed) so validate
  -- accepts the same {type, …fields} shape as instance.create. Already-IRI keys pass through.
  v_ns := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;
  -- 0.4.51: the SAME map create_typed uses. This read composed while create read
  -- the kernel graph — validate ⟺ seal broken one layer below the gate.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_resolved := jsonb_build_object('type', v_type);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_body) LOOP
    CONTINUE WHEN v_key IN ('type', '@id', 'sub');
    IF position(':' in v_key) > 0 THEN v_kiri := v_key;
    ELSIF v_propmap ? v_key THEN v_kiri := v_propmap->>v_key;
    ELSE v_kiri := v_ns || v_key; END IF;
    v_resolved := v_resolved || jsonb_build_object(v_kiri, v_val);
  END LOOP;

  -- project the resolved candidate body to RDF in a scratch graph.
  -- 0.4.62 — THE DRY-RUN CANDIDATE IS THE SEAL'S CANDIDATE, all three parts.
  -- This serialized the body alone, so every requirement arriving by PARENT
  -- CLOSURE was invisible: wave:Pass receives EpochShape via wave:Pass ⊑
  -- ckp:Epoch, so epoch and surfaceDigest are demanded at seal — and this
  -- dry-run said conforms:true to a body missing both (ck-dev's escalation
  -- operation-1786642612862085000, reproduced here on 0.4.61 before fixing).
  -- Same root as the 0.4.60 propmap fix, one layer over: ancestors resolved in
  -- the property MAP but never STAMPED on the dry-run candidate. The derived
  -- stamps join too, exactly as seal composes them, so InstanceShape's
  -- requirements are previewed rather than falsely refused.
  v_ttl := ckp._body_to_ttl(v_resolved, v_subj, v_comp)
        || ckp._parent_closure_ttl(v_type, v_subj, v_comp)
        || ckp._stamps_to_ttl(v_subj, ckp._derived_stamps(v_subj, v_type, v_proj,
             NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), ''), v_comp));
  v_scratch := pgrdf.add_graph('urn:ckp:validate:'||pg_backend_pid());
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    PERFORM pgrdf.parse_turtle(v_ttl, v_scratch, 'urn:ckp:validate#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'sqlstate', '42704', 'detail', SQLERRM);
  END;

  -- Full native W3C SHACL Core report against the COMPOSED SURFACE -- the graph
  -- ckp.seal actually gates on. This validated against <urn:ckp:%s/kernel/ck>,
  -- which holds a Kernel and three organs and NO shapes: measured on the bench,
  -- 30 triples and 0 sh:targetClass, versus a composed surface of 1258 triples
  -- and 27 targets. Nothing could ever be selected, and the only thing standing
  -- between that and a vacuous conforms:true is the no-target guard.
  -- "validate PREDICTS seal" (pgCK#27) was a slogan on all three axes -- shapes
  -- graph, property map, serializer overload. All three now match seal.
  v_report := pgrdf.validate(v_scratch, v_comp, 'native');
  PERFORM pgrdf.clear_graph(v_scratch);

  -- 0.4.72 — SEVERITY PARITY (validate ⟺ seal, fourth axis). The seal now
  -- refuses on Violations only and surfaces Warnings; a dry-run that reported
  -- conforms=false for a warnings-only body would predict a refusal the seal
  -- does not make — the exact split class this function exists to prevent.
  -- Partition identically: `conforms` reflects Violations; `warnings` carries
  -- the guidance band.
  DECLARE v_viol jsonb; v_warn jsonb;
  BEGIN
    SELECT COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IS DISTINCT FROM 'sh:Warning'
                                           AND r->>'resultSeverity' IS DISTINCT FROM 'sh:Info'), '[]'::jsonb),
           COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IN ('sh:Warning','sh:Info')), '[]'::jsonb)
      INTO v_viol, v_warn
      FROM jsonb_array_elements(COALESCE(v_report->'results', '[]'::jsonb)) r;
    RETURN jsonb_build_object('ok', true, 'type', v_type,
      'conforms',   (jsonb_array_length(v_viol) = 0),
      'violations', v_viol,
      'warnings',   v_warn,
      'report',     v_report);
  END;
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
  -- VoteShape declares ckp:voteValue; this read only 'value', so a caller using
  -- the declared name got invalid_vote_value. Accept both.
  v_value     text := COALESCE(p_payload->>'value', p_payload->>'voteValue');
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_vote_value', 'sqlstate', '22023', 'value', v_value);
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
  END IF;

  -- 2. the Proposal must exist and still be pending.
  SELECT body INTO v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'sqlstate', '42704', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'sqlstate', '55000',
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
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'sqlstate', '23514', 'violations', v_report->'violations');
  END IF;

  -- 4. seal the Vote (sealed by the session identity — a human approval is indistinguishable).
  v_body := jsonb_build_object(
    'type',         C||'Vote',
    '@id',          'ckp://Vote#'||v_vid,
    C||'about',     v_about,
    C||'voteValue', v_value
  );
  PERFORM ckp.seal(v_vid, v_body);

  -- 5. quorum: DISTINCT accountable parties (0.4.62) — see ckp.apply for the
  -- mechanism and ck-dev's finding. Votes are not approvals; parties are.
  SELECT count(DISTINCT body->>(C||'createdBy')) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote'
      AND body->>(C||'about') = v_about
      AND body->>(C||'voteValue') = 'approve'
      AND COALESCE(body->>(C||'createdBy'),'') NOT LIKE 'urn:ckp:participant:anon:%';

  RETURN jsonb_build_object('ok', true, 'vote', v_vid, 'proposal', v_about, 'value', v_value,
                            'approvals', v_approvals, 'quorum', v_quorum,
                            'quorum_met', v_approvals >= v_quorum, 'verified', ckp.verify(v_vid));
END;
$function$
;


-- 0.4.106 (C-15) — THE SWEEP'S OWN CODES. Typing every refusal site surfaced
-- eight codes the registry never carried: the apply-stage projector wrappers
-- (55000 — the governed change could not be projected, and the nested detail
-- travels VERBATIM), the delegate seam (0A000 — not refused-by-law but
-- not-served-at-THIS-tier: the tool tier answers on the declared topics), and
-- the kernel-resolution wrapper (42704). Registered in the same act as the
-- sites that return them — a code returned but not registered is exactly the
-- unregistered prose C-15 exists to retire.
INSERT INTO ckp.refusal_registry (code, sqlstate, teaches) VALUES
  ('affordance_register_failed', '55000', 'a governed add_affordance could not compile/register its plan; the nested detail is the engine''s own message, verbatim'),
  ('obligation_register_failed', '55000', 'a governed add_proof_obligation could not register; the nested detail names the strict-parse clause that refused'),
  ('graph_apply_failed',         '55000', 'the op translated but the kernel graph refused the quads; the nested detail is the graph layer''s refusal, verbatim'),
  ('policy_apply_refused',       '55000', 'set_kernel_policy''s patch was refused downstream — the nested detail says WHICH clause (shape bound or undeclared key); never flattened into "apply failed"'),
  ('op_translate_failed',        '22023', 'the proposal''s detail could not project a change (malformed targetClass/path/properties); fix the detail and re-propose'),
  ('governance_plane_unavailable','55000', NULL),
  ('project_error',              '42704', 'the kernel named by the transport could not be resolved to a sealed ckp:Kernel or rostered segment; ckp._project_explain carries the clause'),
  ('verb_delegated',             '0A000', 'delegate marker, not a gate refusal: dispatch names the tool tier and the declared inTopic/outTopic carry the call; 0A000 = not served at THIS tier'),
  -- and the two this very gate caught on its first run: returned since
  -- 0.4.102/0.4.99 and never registered — the exact defect class C-15 retires,
  -- committed by the same hands that then built the gate. The gate works.
  ('not_owner',                  '42501', 'the acting identity is not the declared owner of the target project; quorum answers whether enough parties AGREED, ownership answers whether THIS party may enact — ask the owner'),
  ('ownership_not_patchable',    '42501', 'ckp:ownedBy is server-derived at germination and no transfer verb exists; both the germinate guard and the apply gate read it, so a patchable owner would void both')
ON CONFLICT (code) DO UPDATE SET sqlstate = EXCLUDED.sqlstate, teaches = EXCLUDED.teaches;
