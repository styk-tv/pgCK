-- pgck--0.4.83--0.4.84.sql — THE REPLY TELLS YOU WHAT IT IS (P3 + B2; suite
-- cases 14 and 15; cklib's D7 shim retires).
--
-- P3 / HANDOVER B4 — the reply carries what the seal wrote. The four stamps
-- (M1 createdBy · M2 producedBy · M3 sealedAtEpoch · M4 conformsToShape) were
-- stored by every seal and nulled/absent in every reply. ONE reader
-- (ckp._stamped) over the STORED body, appended by the write sites:
-- instance.create (typed + legacy), instance.update (both), instance.link,
-- notify, instance.transition, instance.retire. Keys ride flat, never
-- aggregated; an absent M4 stays ABSENT — withheld, never faked to null.
--
-- B2 — a read reply carries its completeness verdict. ONE builder
-- (ckp._read_verdict): total known ⇒ 'complete'/'truncated' is measured;
-- limit-only ⇒ an answer that fills the limit claims no more than
-- 'possibly_truncated'. Applied at kernels.list, instances.list/last/count,
-- instance.query, instance.reach.
--
-- GENERATED from the baseline bytes — both roads carry identical statements.


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
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}} — the same two shapes instance.validate reads. NOT accepted: @type, which is never read.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
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
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
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
    RETURN jsonb_build_object('ok', false, 'error', 'id_required'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id); END IF;

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
      v_keyiri := v_key;                                    -- already a full IRI
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
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
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;

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

  -- 0.4.83 (B7) — the refusal registry is itself learnable through the door
  -- (a check that is not a verb does not exist): the closed set of refusal
  -- codes, their typed sqlstate classes, and what each teaches.
  WHEN 'surface.refusals' THEN
    res := jsonb_build_object('ok', true,
      'count', (SELECT count(*) FROM ckp.refusal_registry),
      'refusals', COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'code', code, 'sqlstate', sqlstate, 'teaches', teaches))
                    ORDER BY sqlstate, code)
                  FROM ckp.refusal_registry), '[]'::jsonb),
      'note', 'an ok:false whose error is not in this set is fault-shaped, not a refusal');

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
      'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
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
    RETURN jsonb_build_object('ok', false, 'error', 'reason_required', 'id', v_id);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  -- Only a DECLARED retirement blocks a second one. A row carrying the bare
  -- pre-0.4.55 `retired` key and no ckp:retiredAtEpoch was never retired in any
  -- way another kernel can read, so letting the sanctioned verb finish the act is
  -- COMPLETING it, not repeating it and not backfilling it — nothing is invented,
  -- the declared property is simply moved to where the private key already said
  -- it was. This is what lets F15's two observed rows close instead of standing
  -- as scars that every reader has to be told about.
  IF v_body ? (C||'retiredAtEpoch') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_retired', 'id', v_id,
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

CREATE OR REPLACE FUNCTION ckp._query(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  p_type text := p_payload->>'type';
  p_kern text := p_payload->>'kernel';
  p_n    int  := COALESCE((p_payload->>'n')::int, (p_payload->>'limit')::int,
                          CASE WHEN p_verb='instances.last' THEN 10 ELSE 50 END);
  v_res  jsonb;
  v_total bigint;
BEGIN
  IF p_verb = 'instance.get' THEN
    RETURN jsonb_build_object('ok', true, 'instance', ckp._envelope(p_payload->>'id'));
  ELSIF p_verb = 'instances.count' THEN
    SELECT count(*) INTO v_total FROM ckp.instances
      WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
        AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern);
    -- a count IS its own total: returned = total, verdict measured 'complete'
    RETURN jsonb_build_object('ok', true, 'count', v_total)
      || ckp._read_verdict(v_total::int, NULL, v_total);
  ELSE  -- instances.list / instances.last
    v_res := jsonb_build_object('ok', true, 'count', (
        SELECT count(*) FROM ckp.instances
        WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
          AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern)),
      'instances', COALESCE((
        SELECT jsonb_agg(ckp._envelope(id) ORDER BY ts DESC)
        FROM (SELECT id, ts_created ts FROM ckp.instances
          WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
            AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern)
          ORDER BY ts_created DESC LIMIT p_n) s), '[]'::jsonb));
    v_res := v_res || ckp._read_verdict(jsonb_array_length(v_res->'instances'), p_n, (v_res->>'count')::bigint);
    RETURN v_res;
  END IF;
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type', 'type', v_type);
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
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_operator', 'op', v_op,
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
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_filter_key',
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
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'key', v_key_in);
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
          RETURN jsonb_build_object('ok', false, 'error', 'unresolved_shape',
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
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_numeric_value', 'op', v_op, 'value', v_val);
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from);
  END IF;
  -- id-form: a bare instance id resolves to its @id IRI (the form link/materialize_edge wrote);
  -- an absolute IRI passes through. An unresolvable bare id has nothing to reach FROM.
  v_from_iri := ckp._resolve_ref(v_from);
  IF v_from_iri IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'from', v_from, 'resolved', NULL, 'via', v_via,
                              'max_depth', v_max, 'reached', '[]'::jsonb);
  END IF;
  IF v_from_iri !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from, 'resolved', v_from_iri);
  END IF;
  -- injection-safe IRI gate on `via` (always).
  IF v_via IS NULL OR v_via !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- T2: `via` MUST be in the kernel's DECLARED predicate set; a kernel that declares none falls
  -- back to the namespace allowlist (back-compat).
  v_declared := ckp.declared_predicates(v_proj);
  IF jsonb_array_length(v_declared) > 0 THEN
    IF NOT (v_declared @> to_jsonb(v_via)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via, 'declared', v_declared);
    END IF;
  ELSIF NOT (v_via LIKE 'https://conceptkernel.org/%' OR v_via LIKE 'urn:ckp:%') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
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
