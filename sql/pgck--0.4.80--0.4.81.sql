-- pgck--0.4.80--0.4.81.sql — GERMINATION BECOMES REACHABLE, AND THE PAYLOAD
-- STOPS BEING GUESSED.
--
-- (1) MEASURED THROUGH THE DOOR on 0.4.80, freshly rebuilt bundle:
--       ck_do kernel.germinate {...}  ->  {"ok": false, "error": "unknown_affordance"}
--     while ckp.dispatch has carried `WHEN 'kernel.germinate' THEN` since 0.4.43.
--     The registry is the SOLE routing authority (CI-B-1), so dispatch refused
--     before reaching the implementation. THE ONE ACT THAT CREATES A KERNEL was
--     unreachable by the only route end users have. This is the #56 gap seen
--     from its other side: usually a verb routes with nothing declaring it;
--     this one was implemented with nothing routing it.
--
-- (2) Four substitutions deleted, chosen by one rule: WOULD A WRONG VALUE HERE
--     FAIL LOUDLY, OR SUCCEED PLAUSIBLY? A default that fails loudly is fine
--     (a bad nats_url dies on connect). One that succeeds plausibly is not a
--     default — it is an invented answer:
--       bump_epoch / compile_plans   DEFAULT 'pgck'      <- this repo's own name,
--         hardcoded as the kernel whose epoch gets bumped on every deployment
--       germinate_kernel  p_kind     DEFAULT 'personal'  <- a Project's kind
--       kernel.germinate  projectKind COALESCE 'personal' <- a SHAPE-REQUIRED
--         field filled BEFORE validation, so the gate approved content the
--         caller never supplied and ProjectShape's sh:in never got to speak
--       notify            predicate  COALESCE 'notifies' <- the predicate of an
--         edge: the MEANING of the link, invented when unstated
--
--     Every call site of bump_epoch/compile_plans already passes its argument,
--     so removing those defaults breaks nothing and removes only the ability to
--     act on a kernel named after this repository.
--
-- Third in a family: 'demo' (naming plane, 0.4.79), 'pgck-localhost' (evidence
-- plane, 0.4.80), and now our own repo name plus three payload fields. Same
-- mechanism each time — a value correct as a local convenience, in a slot no
-- gate reads.

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane)
VALUES ('pgck','kernel.germinate','input.kernel.pgck.action.kernel.germinate','instance')
ON CONFLICT (kernel, verb) DO NOTHING;

-- Postgres refuses to REMOVE a parameter default via CREATE OR REPLACE
-- ("cannot remove parameter defaults from existing function"), so each of these
-- is dropped and recreated. Safe: plpgsql resolves calls at execution time, and
-- every call site already passes the argument explicitly.
DROP FUNCTION IF EXISTS ckp.bump_epoch(text);
DROP FUNCTION IF EXISTS ckp.compile_plans(text);
DROP FUNCTION IF EXISTS ckp.germinate_kernel(text, text, text);

CREATE OR REPLACE FUNCTION ckp.bump_epoch(p_kernel text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_epoch integer;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  UPDATE ckp.kernel_epoch SET epoch = epoch + 1 WHERE kernel = p_kernel RETURNING epoch INTO v_epoch;
  PERFORM ckp.compile_plans(p_kernel);   -- recompile at the new epoch (same txn)
  PERFORM pgrdf.plan_cache_clear();       -- invalidate the engine SPARQL plan cache (same txn)
  RETURN v_epoch;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.compile_plans(p_kernel text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_epoch integer;
  v_n     integer := 0;
  r       record;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = p_kernel;

  FOR r IN
    SELECT * FROM (VALUES
      ('instance.get',
        '{"kind":"sql","statement":"SELECT body FROM ckp.instances WHERE id = $1","params":["id"]}'::jsonb),
      ('instance.count',
        '{"kind":"sql","statement":"SELECT count(*) AS n FROM ckp.instances","params":[]}'::jsonb)
    ) AS cat(verb, plan)
  LOOP
    INSERT INTO ckp.plans(kernel, verb, epoch, plan)
      VALUES (p_kernel, r.verb, v_epoch, r.plan)
      ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
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
  -- p_project is ONE transport segment, not an IRI. The metacharacter test alone
  -- let ':' and '/' through, so a caller passing the project URN
  -- ('urn:ckp:project:ck-lib-js') germinated a graph named
  -- <urn:ckp:urn:ckp:project:ck-lib-js/kernel/ck> -- structurally valid, and
  -- reachable by nobody. Measured on the bench: 22 asserted triples in exactly
  -- that graph. Require a bare segment; the metacharacter case keeps its own
  -- message because the slug is actionable there.
  IF p_project ~ '[.*> \t\r\n]' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', format('kernel id %L carries a NATS subject metacharacter, so it can never be granted. Use %L.',
                      p_project, ckp._slug(p_project)));
  END IF;
  IF p_project !~ '^[a-z0-9]+(-[a-z0-9]+)*$' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', format('kernel id %L is not canonical. A project name is lowercase, dashes optional, one transport segment -- use %L.',
                      p_project, ckp._slug(regexp_replace(p_project, '^.*[:/]', ''))));
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
    res := ckp.wave_signals(p_payload);

  -- one-version alias (0.4.63): routes, answers, and says where to go. Removed
  -- next release — nothing tagged ever carried the old name.
  WHEN 'wave.oracle' THEN
    res := ckp.wave_signals(p_payload)
        || jsonb_build_object('deprecated', 'wave.oracle is wave.signals; this alias is removed next release');

  WHEN 'adoption.check' THEN
    res := ckp.adoption_check(p_payload);

  WHEN 'wave.project' THEN
    res := ckp.wave_project_spine(p_payload);

  WHEN 'surface.typecheck' THEN
    res := ckp.surface_typecheck(p_payload, v_proj);

  WHEN 'surface.unshaped' THEN
    res := ckp.surface_unshaped(v_proj);

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
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
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
    res := ckp.wave_signals(p_payload);

  -- one-version alias (0.4.63): routes, answers, and says where to go. Removed
  -- next release — nothing tagged ever carried the old name.
  WHEN 'wave.oracle' THEN
    res := ckp.wave_signals(p_payload)
        || jsonb_build_object('deprecated', 'wave.oracle is wave.signals; this alias is removed next release');

  WHEN 'adoption.check' THEN
    res := ckp.adoption_check(p_payload);

  WHEN 'wave.project' THEN
    res := ckp.wave_project_spine(p_payload);

  WHEN 'surface.typecheck' THEN
    res := ckp.surface_typecheck(p_payload, v_proj);

  WHEN 'surface.unshaped' THEN
    res := ckp.surface_unshaped(v_proj);

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
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
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

-- ============================================================================
-- 0.4.81 items 2 and 3: STATE IS NOT HEALTH, and a CURIE is refused.
-- ============================================================================
-- (2) surface.check separated `state` (core-only | named | germinated) from
--     `healthy` (is THIS state internally consistent). A brand-new install
--     reported healthy:false with a "wipe signature" on a machine where nothing
--     had ever happened — the check could not tell NEVER EXISTED from WAS
--     DESTROYED. The wipe finding now fires only when a ckp:Kernel IS sealed and
--     its graph is empty, i.e. when something that existed is gone; and an
--     unpinned surface is a finding only after an epoch has actually advanced.
--     The real wipe detector survives, which is the negative control that
--     matters: making core-only healthy must not blind it.
--
-- (3) surface.declared / typecheck / explain refuse `ckp:Project` instead of
--     answering `declared: {}` / `admitted: false`. Nothing expands prefixes
--     here, so a CURIE matched nothing and the verb reported a confident
--     absence about a type the gate judges daily — a caller learned a FALSE
--     contract and could not distinguish it from a real one.
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
  v_state  text;
BEGIN
  -- 0.4.81 — CORE-ONLY SHORT-CIRCUIT. With no kernel named there is no kernel
  -- graph to name, and building 'urn:ckp:'||NULL||'/kernel/ck' produced a NULL
  -- IRI that reached pgrdf.sparql as a parse error — the check crashed on
  -- exactly the state it was taught to call healthy. (Caught by s72, which is
  -- the argument for writing the gate with the change rather than after it.)
  IF v_proj IS NULL THEN
    v_comp := ckp._composed_shapes(NULL);          -- the surface IS core
    RETURN jsonb_build_object(
      'ok', true, 'kernel', NULL, 'state', 'core-only', 'epoch', 0,
      'epoch_resource', NULL,
      'surface', jsonb_build_object('pinned', NULL, 'actual', ckp._surface_digest(v_comp), 'match', NULL),
      'source',  jsonb_build_object('pinned', NULL, 'actual', NULL, 'match', NULL),
      'kernel_graph', NULL,
      'composed_nodeshapes', (SELECT count(*) FROM pgrdf.sparql(format(
         'PREFIX sh: <http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <%s> { ?s a sh:NodeShape } }',
         pgrdf.graph_iri(v_comp)))),
      'modules', '[]'::jsonb,
      'findings', '[]'::jsonb,
      'note', 'no kernel named: the law is loaded and readable (surface.declared, surface.typecheck, instance.validate all answer), and sealing refuses on M2. A complete state, not a fault.',
      'healthy', true);
  END IF;

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
  -- 0.4.81 — STATE IS NOT HEALTH, and an empty kernel graph means different
  -- things in each state. A brand-new install reported `healthy:false` with a
  -- "wipe signature" on a machine where nothing had ever happened: the check
  -- could not tell NEVER EXISTED from WAS DESTROYED, and a diagnostic that is
  -- false on every correct day-one install is the twin of one that can never
  -- fail — nobody trusts it, so it cannot do its job.
  --
  --   core-only   no kernel named. The surface IS core. Complete and correct:
  --               the law is readable, sealing refuses on M2. NOT a fault.
  --   named       a project resolves but no ckp:Kernel is sealed. Germination
  --               is the open next act.
  --   germinated  a Kernel is sealed. NOW an empty graph is a real wipe.
  IF v_proj IS NULL THEN
    v_state := 'core-only';
  ELSIF EXISTS (SELECT 1 FROM ckp.instances
                 WHERE body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Kernel'
                   AND body->>'@id'  = 'urn:ckp:'||v_proj||'/kernel') THEN
    v_state := 'germinated';
  ELSE
    v_state := 'named';
  END IF;

  IF v_kquads = 0 AND v_state = 'germinated' THEN
    v_find := v_find || jsonb_build_array(
      'kernel graph '||v_kiri||' is EMPTY while a ckp:Kernel IS sealed for this project — '||
      'the enforcement surface is composed WITHOUT the kernel''s own shapes. This is the '||
      '2026-08-10 wipe signature: something that existed is gone.');
  END IF;
  IF v_shapes = 0 THEN
    v_find := v_find || jsonb_build_array(
      'composed surface carries ZERO NodeShapes — every gate is vacuous; refuse to trust any conformance result');
  END IF;
  IF v_pin_surf IS NULL AND v_state = 'germinated' AND v_epoch > 0 THEN
    -- Only a fault once the kernel HAS governed: an epoch advanced without
    -- sealing what was in force. Before that, unpinned is the pre-governance
    -- state, reported below as `state`, not as a finding.
    v_find := v_find || jsonb_build_array(
      'epoch '||v_epoch||' is in force but no ckp:Epoch seals its digest — an apply advanced the epoch without recording the surface, so drift is undetectable');
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
    'state', v_state,
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
    'note', CASE v_state
      WHEN 'core-only'  THEN 'no kernel named: the law is loaded and readable, sealing refuses on M2. A complete state, not a fault.'
      WHEN 'named'      THEN 'a project resolves but no ckp:Kernel is sealed — germination is the open next act.'
      ELSE 'a ckp:Kernel is sealed for this project.' END,
    'healthy', jsonb_array_length(v_find) = 0);
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'type', v_type,
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'type', v_type,
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
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
    RETURN jsonb_build_object('ok', false, 'error', 'type_is_a_curie', 'type', v_type,
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
