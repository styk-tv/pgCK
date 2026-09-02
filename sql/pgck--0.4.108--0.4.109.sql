-- pgck 0.4.108 -> 0.4.109
--
-- C-8  · an implicit Signal seals with dwellMillis as ONE hash-chained
--        boundary head, never per event; never-saw seals nothing.
-- C-9  · a Score crossing thresholdPromote DRAFTS a Proposal and the tick
--        seals/votes/applies NOTHING.
-- C-11 · a crossing ENQUEUES and never executes; the drain is bounded,
--        counts attempts, and is fair across kernels.
--
-- The signal→score→clock arc, closing the last three obligations:
--
-- signal.boundary — presence traces stay organ-local (R-14); ONE implicit
-- Signal seals per boundary with the aggregated dwellMillis, chained by the
-- SAME HMAC ledger that chains everything (one chain, never a bespoke
-- second). Never-saw seals NOTHING and answers as a SUCCESS: the absence of
-- a Signal is correctly free, and sealing a zero would manufacture evidence
-- of an encounter that did not happen.
--
-- score.tick — scores DERIVED, never asserted, from sealed Signals under the
-- kernel's OWN law (substrate defaults named, never invented per call).
-- Every provenance link resolves: Score → wasGeneratedBy → a real sealed Run
-- → realizes → the sealed score.tick Affordance. A crossing DRAFTS a
-- Proposal (proposalState 'draft' — lawful since wave-3.12-pass-3) — ONE
-- standing draft per concept, because a queue of identical drafts is
-- pressure, not information — and the tick seals no vote, applies nothing,
-- bumps no epoch. The constitutional limit, in code where probes measure it.
--
-- orbit queue — ckp.orbit_job + orbit_enqueue (detection only; UNIQUE
-- (kernel, crossing_at) makes re-detection free) + orbit_drain (at most
-- p_max jobs, AT MOST ONE PER KERNEL — the wait scales with how many
-- kernels are busy, never with how much the busiest queued; a failing job
-- counts attempts and PARKS at five with its last error — re-selected
-- forever presents as THE LOOP WORKING, 0.4.80) + orbit_tick, the
-- bgworker's one call per tick (src/orbit_drain.rs, guarded on
-- to_regprocedure so a pre-0.4.109 catalog keeps a silent no-op tick).
--
-- Verbs signal.boundary / score.tick routed and declared (the C-14 backfill
-- below seals the new declarations — both halves, one act).
--
-- Controls: s89 (wired into smoke-s4); TDD C-8/C-9/C-11 upgraded from
-- existence stubs to behaviour probes with their negative controls.

CREATE TABLE IF NOT EXISTS ckp.orbit_job (
  id            bigserial PRIMARY KEY,
  kernel        text NOT NULL,
  crossing_at   timestamptz NOT NULL,
  state         text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','done','failed')),
  attempt_count int NOT NULL DEFAULT 0,
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  done_at       timestamptz,
  UNIQUE (kernel, crossing_at)
);


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
  WHEN 'orbit.next' THEN
    res := ckp.next_crossing(COALESCE(p_payload->>'kernel', v_proj));
  WHEN 'signal.boundary' THEN
    res := ckp.signal_boundary(p_payload);
  WHEN 'score.tick' THEN
    res := ckp.score_tick(COALESCE(p_payload->>'kernel', v_proj));
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
  WHEN 'orbit.next' THEN
    res := ckp.next_crossing(COALESCE(p_payload->>'kernel', v_proj));
  WHEN 'signal.boundary' THEN
    res := ckp.signal_boundary(p_payload);
  WHEN 'score.tick' THEN
    res := ckp.score_tick(COALESCE(p_payload->>'kernel', v_proj));
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

CREATE OR REPLACE FUNCTION ckp.orbit_drain(p_max integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  r record; v_res jsonb; v_done int := 0; v_failed int := 0; v_report jsonb := '[]'::jsonb;
BEGIN
  -- 0.4.109 (C-11) — BOUNDED, ATTEMPT-COUNTED, FAIR. At most p_max jobs per
  -- drain and AT MOST ONE PER KERNEL — round-robin, so the wait scales with
  -- how many kernels are busy, never with how much the busiest one queued
  -- (SUBSTRATE-SCOPE §4.2). A failing job counts its attempts and at five is
  -- parked as 'failed' with its last error — re-selected-forever presents as
  -- THE LOOP WORKING (0.4.80), and a parked job is visible where a spinning
  -- one is not. The work itself is the DRAFT-only score tick: even executed,
  -- a crossing seals no vote and applies nothing.
  FOR r IN
    SELECT DISTINCT ON (kernel) id, kernel, crossing_at, attempt_count
      FROM ckp.orbit_job
     WHERE state = 'queued'
     ORDER BY kernel, crossing_at
     LIMIT GREATEST(p_max, 1)
  LOOP
    BEGIN
      PERFORM 1 FROM ckp.orbit_job WHERE id = r.id FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN CONTINUE; END IF;
      v_res := ckp.score_tick(r.kernel);
      IF (v_res->>'ok')::boolean IS TRUE THEN
        UPDATE ckp.orbit_job SET state='done', done_at=now(), attempt_count=attempt_count+1 WHERE id = r.id;
        v_done := v_done + 1;
        v_report := v_report || jsonb_build_object('kernel', r.kernel, 'job', r.id, 'state', 'done',
                                                   'drafted', v_res->'drafted');
      ELSE
        RAISE EXCEPTION '%', COALESCE(v_res->>'error','score_tick refused');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE ckp.orbit_job
         SET attempt_count = attempt_count + 1,
             last_error = SQLERRM,
             state = CASE WHEN attempt_count + 1 >= 5 THEN 'failed' ELSE 'queued' END
       WHERE id = r.id;
      v_failed := v_failed + 1;
      v_report := v_report || jsonb_build_object('kernel', r.kernel, 'job', r.id, 'state', 'attempt_failed', 'error', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'done', v_done, 'failed', v_failed, 'report', v_report);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.orbit_enqueue()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  r record; v_n int := 0; v_due timestamptz;
BEGIN
  -- 0.4.109 (C-11) — A CROSSING ENQUEUES AND NEVER EXECUTES. For every sealed
  -- Kernel declaring orbit law, the most recent PAST crossing is computed
  -- (the same arithmetic next_crossing exposes) and enqueued exactly once —
  -- UNIQUE (kernel, crossing_at) makes re-detection free. Nothing runs here:
  -- detection and execution are different acts with different budgets.
  FOR r IN
    SELECT substring(i.body->>'@id' from '^urn:ckp:([a-z0-9-]+)/kernel$') AS kernel,
           (i.body->>(C||'orbitPeriodSeconds'))::int AS period,
           (i.body->>(C||'orbitAnchor'))::timestamptz AS anchor
      FROM ckp.instances i
     WHERE i.body->>'type' = C||'Kernel'
       AND i.body->>(C||'orbitPeriodSeconds') IS NOT NULL
       AND i.body->>(C||'orbitAnchor') IS NOT NULL
  LOOP
    CONTINUE WHEN r.kernel IS NULL OR r.period IS NULL OR r.period <= 0 OR r.anchor IS NULL OR r.anchor > now();
    v_due := r.anchor + (floor(EXTRACT(epoch FROM (now() - r.anchor)) / r.period)::bigint * r.period) * interval '1 second';
    CONTINUE WHEN v_due <= r.anchor;
    INSERT INTO ckp.orbit_job(kernel, crossing_at) VALUES (r.kernel, v_due)
      ON CONFLICT (kernel, crossing_at) DO NOTHING;
    IF FOUND THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.orbit_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_q int; v_d jsonb; v_prev text := current_setting('ckp.requester', true);
BEGIN
  -- The bgworker's one call per tick: detect crossings, drain fairly. The
  -- tick names its service identity (0.4.64) for the seals the DRAFT-only
  -- work produces, and restores whatever the session carried.
  IF COALESCE(NULLIF(trim(v_prev), ''), '') = '' THEN
    PERFORM set_config('ckp.requester', 'svc:orbit-tick', true);
  END IF;
  v_q := ckp.orbit_enqueue();
  v_d := ckp.orbit_drain(4);
  PERFORM set_config('ckp.requester', COALESCE(v_prev, ''), true);
  RETURN jsonb_build_object('enqueued', v_q) || v_d;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.score_tick(p_kernel text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj  text := COALESCE(p_kernel, ckp._project());
  v_kbody jsonb;
  v_wa numeric; v_wd numeric; v_wi numeric; v_tau numeric; v_promote numeric;
  v_epoch_before int; v_epoch_after int;
  v_run text; v_now text;
  r record;
  v_scores jsonb := '[]'::jsonb;
  v_drafted jsonb := '[]'::jsonb;
  v_pid text;
BEGIN
  -- 0.4.109 (C-9) — THE TICK MAY DRAFT ONLY. Scores are DERIVED, never
  -- asserted: computed from sealed Signals under the kernel's OWN law
  -- (weights and tau from the sealed Kernel, substrate defaults where the
  -- kernel declares none — 1.0 / -0.8 / 0.5 / 60000ms, each named in the
  -- law's own comments), sealed with wasGeneratedBy naming a real ckp:Run
  -- whose realizes names the sealed score.tick Affordance — every link of
  -- F-P2-5's phantom chain made to resolve. A score crossing
  -- thresholdPromote DRAFTS a Proposal (proposalState 'draft', in the closed
  -- set since wave-3.12-pass-3) and the tick seals NO votes, applies
  -- NOTHING, and bumps NO epoch — promotion to pending is a party's own
  -- sealed act. A kernel declaring no thresholdPromote crosses nothing:
  -- absence imposes nothing, exactly as everywhere else.
  SELECT i.body INTO v_kbody FROM ckp.instances i
   WHERE i.body->>'@id' = 'urn:ckp:'||v_proj||'/kernel' AND i.body->>'type' = C||'Kernel'
   ORDER BY i.ts_created DESC LIMIT 1;
  IF v_kbody IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'sqlstate', '42704',
      'hint', format('no sealed ckp:Kernel at urn:ckp:%s/kernel — a score must be computed under SOMEONE''S law', v_proj));
  END IF;
  v_wa      := COALESCE((v_kbody->>(C||'weightAssent'))::numeric,   1.0);
  v_wd      := COALESCE((v_kbody->>(C||'weightDissent'))::numeric, -0.8);
  v_wi      := COALESCE((v_kbody->>(C||'weightImplicit'))::numeric, 0.5);
  v_tau     := COALESCE((v_kbody->>(C||'tauImplicitMillis'))::numeric, 60000);
  v_promote := (v_kbody->>(C||'thresholdPromote'))::numeric;
  SELECT epoch INTO v_epoch_before FROM ckp.kernel_epoch WHERE kernel = v_proj;

  -- one Run for this computation — sealed FIRST so every Score's
  -- wasGeneratedBy resolves the moment it lands.
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_run := 'run-scoretick-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
  PERFORM ckp.seal(v_run, jsonb_build_object(
    'type', C||'Run', '@id', 'urn:ckp:'||v_proj||'/run/'||v_run,
    C||'realizes', 'ckp://Affordance#pgck.score.tick',
    C||'runOf', 'urn:ckp:'||v_proj||'/kernel/ck',
    C||'startedAt', v_now, C||'endedAt', v_now,
    C||'runState', 'completed'));

  FOR r IN
    SELECT i.body->>(C||'about') AS about,
           round(sum(CASE i.body->>(C||'signalPolarity')
                       WHEN 'assent'  THEN v_wa
                       WHEN 'dissent' THEN v_wd
                       WHEN 'implicit' THEN v_wi * (1 - exp(-COALESCE((i.body->>(C||'dwellMillis'))::numeric,0) / v_tau))
                       ELSE 0 END)::numeric, 4) AS score
      FROM ckp.instances i
     WHERE i.body->>'type' = C||'Signal'
       AND i.body->>(C||'producedBy') = 'urn:ckp:'||v_proj||'/kernel/ck'
       AND i.body->>(C||'about') IS NOT NULL
     GROUP BY 1 ORDER BY 1
  LOOP
    PERFORM ckp.seal('score-'||md5(v_proj||r.about)||'-'||COALESCE(v_epoch_before,0), jsonb_build_object(
      'type', C||'Score', '@id', 'ckp://Score#'||md5(v_proj||r.about)||'-'||COALESCE(v_epoch_before,0),
      C||'about', r.about,
      C||'scoreValue', to_jsonb(r.score),
      C||'computedAtEpoch', to_jsonb(COALESCE(v_epoch_before,0)),
      C||'wasGeneratedBy', 'urn:ckp:'||v_proj||'/run/'||v_run));
    v_scores := v_scores || jsonb_build_object('about', r.about, 'score', r.score);
    IF v_promote IS NOT NULL AND r.score >= v_promote
       -- one standing draft per concept: a crossing that has already drafted
       -- does not draft AGAIN on every tick — a queue of identical drafts is
       -- pressure, not information, and the tick must never generate pressure.
       AND NOT EXISTS (SELECT 1 FROM ckp.instances d
                        WHERE d.body->>'type' = C||'Proposal'
                          AND d.body->>(C||'about') = r.about
                          AND d.body->>(C||'proposalState') = 'draft') THEN
      v_pid := 'proposal-draft-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
      PERFORM ckp.seal(v_pid, jsonb_build_object(
        'type', C||'Proposal', '@id', 'ckp://Proposal#'||v_pid,
        C||'about', r.about,
        C||'proposalState', 'draft',
        C||'proposalOp', 'add_class',
        C||'requiresQuorum', '2',
        'proposalDetail', jsonb_build_object('class', r.about,
          'draftedBecause', format('score %s crossed thresholdPromote %s at epoch %s', r.score, v_promote, COALESCE(v_epoch_before,0)))));
      v_drafted := v_drafted || jsonb_build_object('proposal', v_pid, 'about', r.about, 'score', r.score);
    END IF;
  END LOOP;

  SELECT epoch INTO v_epoch_after FROM ckp.kernel_epoch WHERE kernel = v_proj;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj,
    'epoch', COALESCE(v_epoch_before,0),
    'epochUnchanged', v_epoch_before IS NOT DISTINCT FROM v_epoch_after,
    'run', 'urn:ckp:'||v_proj||'/run/'||v_run,
    'scores', v_scores, 'drafted', v_drafted,
    'law', jsonb_build_object('weightAssent', v_wa, 'weightDissent', v_wd,
      'weightImplicit', v_wi, 'tauImplicitMillis', v_tau,
      'thresholdPromote', v_promote,
      'defaultsNote', 'values absent from the sealed Kernel are the NAMED substrate defaults, never invented per call'),
    'note', 'the tick may DRAFT only — no vote sealed, nothing applied, no epoch advanced; promotion to pending is a party''s own act');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.signal_boundary(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_about  text := p_payload->>'about';
  v_dwell  bigint := (p_payload->>'dwellMillis')::bigint;
  v_events int := COALESCE((p_payload->>'events')::int,
                           CASE WHEN p_payload ? 'dwellMillis' THEN 1 ELSE 0 END);
  v_id text;
BEGIN
  -- 0.4.109 (C-8) — ONE HASH-CHAINED BOUNDARY HEAD, NEVER PER EVENT. Presence
  -- and dwell TRACES accumulate in the caller's own organ (R-14 — the raw
  -- trace never crosses); what seals is ONE implicit Signal per boundary,
  -- carrying the aggregated dwellMillis. The hash chain is not new machinery:
  -- every seal already lands on the HMAC ledger with a prev_seq backlink, so
  -- the boundary head is chained by the same instrument that chains
  -- everything — one chain, not a bespoke second one.
  --
  -- NEVER-SAW SEALS NOTHING, and that is a SUCCESS, not a refusal: the
  -- never-saw state is the absence of a Signal, which is correctly free.
  -- Sealing a zero would manufacture evidence of an encounter that did not
  -- happen.
  IF v_about IS NULL OR btrim(v_about) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'sqlstate', '22004',
      'hint', 'signal.boundary needs {about: <concept IRI>, dwellMillis, events}');
  END IF;
  IF v_events = 0 OR v_dwell IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'sealed', false, 'reason', 'never_saw',
      'hint', 'the never-saw state is the absence of a Signal, which is correctly free — nothing seals');
  END IF;
  v_id := 'sigb-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
  PERFORM ckp.seal(v_id, jsonb_build_object(
    'type', C||'Signal', '@id', 'ckp://Signal#'||v_id,
    C||'about', v_about,
    C||'signalPolarity', 'implicit',
    C||'dwellMillis', to_jsonb(v_dwell)));
  RETURN jsonb_build_object('ok', true, 'sealed', true, 'id', v_id,
    'verified', ckp.verify(v_id), 'events', v_events,
    'note', format('one boundary head for %s event(s); the raw trace stays organ-local (R-14); the ledger chain IS the hash chain', v_events));
END;
$function$
;


INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgck','signal.boundary','input.kernel.pgck.action.signal.boundary','instance'),
  ('pgck','score.tick','input.kernel.pgck.action.score.tick','instance')
ON CONFLICT (kernel, verb) DO NOTHING;

SELECT ckp.declare_routed_affordances();
