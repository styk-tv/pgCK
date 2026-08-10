-- pgck 0.4.37 -> 0.4.38 — B3: the store-level G-1 auditor, and B1a: authority
-- resolved by traversal. Both READS, both reporting absence rather than filling it.
--
-- G-1, RESTATED FROM THE CONTRACT. Body locality (§4.2) means the instance gate
-- reads the candidate body plus its stamped parent closure and NOTHING a
-- referenced node carries. So cross-node integrity — a Grant really targeting an
-- Organ, an Affordance's derivedBy really naming a Materialization, an Adoption's
-- adopts really naming a Module — is *not checkable at the gate*, by design, and
-- the root declares it as a gap rather than wearing it as enforcement (§4.5). The
-- conformant path is a store-level check over sealed rows. This is that check.
-- Measured proof it is needed: an Affordance naming
-- urn:ckp:demo/materialization/DOES-NOT-EXIST sealed cleanly on 2026-08-10.
--
-- WHAT IT CLOSES. pgCK#59 point 2 — "stored rows carry none of the four stamps,
-- so a store-level audit is vacuous" — was made *possible* by 0.4.33 persisting
-- the stamps and is made REAL here: the audit exists, runs over sealed rows, and
-- composes the parent closure the way the gate does rather than re-deriving it.
--
-- THE VACUOUS-SEAL DETECTOR. ckp:conformsToShape is omitted, never invented, when
-- no shape targets the candidate (0.4.28's rule). So a sealed row LACKING it is a
-- row that passed a gate which was targeting nothing — the a1-gate-probe scar is
-- the worked example. That absence is the most honest vacuity signal the substrate
-- has, and until now nothing read it. `vacuous_seals` counts them.
--
-- B1a — WHAT MAY I DO HERE, NOW. SPEC.CK-SEMANTIC-PERSONA §3 SHOULD: authority is
-- a traversal over sealed edges (Participant -memberIs- Membership -holdsRole-
-- Role -grant- Grant -permTarget- Organ), computed at need, never a cached
-- attribute. Surfaced by CK.Lib.Js's I5: a client discovers its grants by
-- violation, having no way to ask. ckp.authority_of answers the question and — the
-- point — reports an EMPTY chain as empty, so "no authority sealed" is visible
-- instead of being indistinguishable from "authority not checked".

CREATE OR REPLACE FUNCTION ckp.integrity_check(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj text := COALESCE(p_project, NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_comp int;
  v_giri text;
  v_find jsonb := '[]'::jsonb;
  v_total int; v_unattr int; v_vac int; v_vac_new int;
  r record;
BEGIN
  v_comp := ckp._composed_shapes(v_proj);
  SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = v_comp;

  SELECT count(*) INTO v_total FROM ckp.instances;

  -- 1. ATTRIBUTION over sealed rows. InstanceShape requires createdBy; a stored
  -- row without it predates 0.4.33 or bypassed the seal. Named, not assumed.
  SELECT count(*) INTO v_unattr FROM ckp.instances
   WHERE NOT (body ? (N||'createdBy'));
  IF v_unattr > 0 THEN
    v_find := v_find || jsonb_build_array(
      v_unattr||' sealed row(s) carry no ckp:createdBy — unattributable work (pre-0.4.33 seals)');
  END IF;

  -- 2. VACUOUS SEALS. conformsToShape is omitted rather than invented when no
  -- shape targeted the candidate, so its absence IS the vacuity signal.
  -- Pre-governance rows (sealedAtEpoch 0) are SCARS: sealed before the root was in
  -- force, unfixable by construction (nothing is ever unsealed), and legitimate
  -- history under the S5 ruling — fence, never backfill. They are reported under
  -- `historical`, NOT as findings: a check that can never go green trains its
  -- reader to ignore it, which is how a real defect gets missed. A vacuous seal at
  -- epoch >= 1 is a live defect and IS a finding.
  SELECT count(*) INTO v_vac FROM ckp.instances
   WHERE NOT (body ? (N||'conformsToShape'))
     AND COALESCE((body->>(N||'sealedAtEpoch'))::int, 0) = 0;
  SELECT count(*) INTO v_vac_new FROM ckp.instances
   WHERE NOT (body ? (N||'conformsToShape'))
     AND COALESCE((body->>(N||'sealedAtEpoch'))::int, 0) > 0;
  IF v_vac_new > 0 THEN
    v_find := v_find || jsonb_build_array(
      v_vac_new||' row(s) sealed AT epoch >= 1 carry no ckp:conformsToShape — they passed a gate '||
      'that targeted nothing. Post-adoption vacuity is a defect, not history.');
  END IF;

  -- 3. G-1 PROPER: cross-node references the gate cannot check. Each is reported
  -- with its subject so the finding is actionable, never a bare count.
  FOR r IN
    SELECT i.id, i.body->>(N||'derivedBy') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Affordance' AND i.body ? (N||'derivedBy')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances m
                        WHERE m.body->>'type' = N||'Materialization'
                          AND m.body->>'@id' = i.body->>(N||'derivedBy'))
       AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                        WHERE s.body->>'type' = N||'Supersession'
                          AND s.body->>(N||'supersedes') = i.body->>'@id')
  LOOP
    v_find := v_find || jsonb_build_array(
      'DANGLING derivedBy: affordance '||r.id||' names '||r.ref||' — no sealed Materialization. '||
      'The root says a hand-registered action cannot hide; body locality means the gate cannot enforce it.');
  END LOOP;

  FOR r IN
    SELECT i.id, i.body->>(N||'inShape') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Affordance' AND i.body ? (N||'inShape')
       AND ckp._affordance_schema(i.body->>(N||'inShape'), v_comp) IS NULL
       -- withdrawal is a sealed act (Supersession), never a delete: a superseded
       -- affordance is out of force and must not keep raising.
       AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                        WHERE s.body->>'type' = N||'Supersession'
                          AND s.body->>(N||'supersedes') = i.body->>'@id')
  LOOP
    v_find := v_find || jsonb_build_array(
      'UNRESOLVABLE inShape: affordance '||r.id||' names '||r.ref||' — not in the composed surface, '||
      'so no input contract can be derived for it.');
  END LOOP;

  FOR r IN
    SELECT i.id, i.body->>(N||'adopts') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Adoption' AND i.body ? (N||'adopts')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances m
                        WHERE m.body->>'type' = N||'Module'
                          AND m.body->>'@id' = i.body->>(N||'adopts'))
  LOOP
    v_find := v_find || jsonb_build_array(
      'ADOPTION without a sealed Module: '||r.id||' adopts '||r.ref||' — the digest it claims to '||
      'pin is not on the ledger.');
  END LOOP;

  -- 4. The §4.5 worked examples: a Grant must target an Organ, a Membership must
  -- hold a Role. Zero rows today; the check exists so the first wrong one is seen.
  FOR r IN
    SELECT i.id, i.body->>(N||'permTarget') AS ref FROM ckp.instances i
     WHERE i.body->>'type' = N||'Grant' AND i.body ? (N||'permTarget')
       AND NOT EXISTS (SELECT 1 FROM ckp.instances o
                        WHERE o.body->>'@id' = i.body->>(N||'permTarget')
                          AND o.body->>'type' IN (N||'Organ', N||'CK', N||'TOOL', N||'DATA'))
  LOOP
    v_find := v_find || jsonb_build_array('GRANT targets a non-Organ: '||r.id||' -> '||r.ref);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj,
    'sealed_rows', v_total,
    'unattributed', v_unattr,
    'historical', jsonb_build_object('pre_governance_vacuous_seals', v_vac,
      'note', 'sealed before the root was in force; unfixable and legitimate — fence, never backfill'),
    'vacuous_seals_live', v_vac_new,
    'findings', v_find,
    'healthy', jsonb_array_length(v_find) = 0);
END;
$function$
;

-- B1a — the authority face, resolved at need (never cached, never asserted).
CREATE OR REPLACE FUNCTION ckp.authority_of(p_participant text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_who text := COALESCE(p_participant, NULLIF(current_setting('ckp.requester', true), ''));
  v_anon boolean := v_who IS NULL;
  v_mem jsonb; v_grants jsonb;
BEGIN
  -- Anonymous is a TIER, not an identity: nothing durable accretes to it
  -- (persona spec PR1), so it has no chain to traverse and saying so is the
  -- answer — not an empty list that reads like "checked and found none".
  IF v_anon THEN
    RETURN jsonb_build_object('ok', true, 'identity', NULL, 'tier', 'anonymous',
      'memberships', '[]'::jsonb, 'grants', '[]'::jsonb,
      'note', 'anonymous tier: no verified identity, so no authority chain exists to resolve. '||
              'Transport grants (events-only, no publish) are minted at admission and are not '||
              'readable here — see SPEC.PGCK.IDENTITY-PATH.');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('membership', m.body->>'@id',
                                      'memberOf',  m.body->>(N||'memberOf'),
                                      'holdsRole', m.body->>(N||'holdsRole')))
    INTO v_mem
  FROM ckp.instances m
  WHERE m.body->>'type' = N||'Membership' AND m.body->>(N||'memberIs') = v_who;

  SELECT jsonb_agg(jsonb_build_object('grant', g.body->>'@id',
                                      'permTarget', g.body->>(N||'permTarget'),
                                      'permission', g.body->>(N||'permission')))
    INTO v_grants
  FROM ckp.instances g
  WHERE g.body->>'type' = N||'Grant'
    AND g.body->>(N||'grantedVia') IN (
      SELECT r.body->>'@id' FROM ckp.instances r
       WHERE r.body->>'type' = N||'Role'
         AND r.body->>'@id' IN (SELECT m.body->>(N||'holdsRole') FROM ckp.instances m
                                 WHERE m.body->>'type' = N||'Membership'
                                   AND m.body->>(N||'memberIs') = v_who));

  RETURN jsonb_build_object('ok', true, 'identity', v_who, 'tier', 'verified',
    'memberships', COALESCE(v_mem, '[]'::jsonb),
    'grants', COALESCE(v_grants, '[]'::jsonb),
    'note', CASE WHEN v_mem IS NULL
      THEN 'no sealed Membership for this identity — the authority chain is EMPTY, which is '||
           'not the same as unchecked. Dispatch is currently governed by the transport tier '||
           'and the role floor, not by this chain.'
      ELSE NULL END);
END;
$function$
;

REVOKE ALL ON FUNCTION ckp.integrity_check(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp.integrity_check(text) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp.integrity_check(text) TO ck_substrate;
REVOKE ALL ON FUNCTION ckp.authority_of(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp.authority_of(text) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp.authority_of(text) TO ck_substrate;

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','integrity.check','input.kernel.pgCK.action.integrity.check','instance'),
  ('pgCK','authority.mine', 'input.kernel.pgCK.action.authority.mine', 'instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'instance', refreshed_at = now();

-- The door, carrying both verbs. Spelled identically to the baseline (rule 3).
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
