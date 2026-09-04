-- pgck 0.4.111 -> 0.4.112
--
-- KNOW BEFORE YOU ACT, AND AT THE ACT (operator ruling 2026-09-04: "this
-- entire system is based on the fact that validation is cheap — so run it
-- and know before you act").
--
-- The census (fleet.adoptions, 0.4.111/s90) and the audit (adoption.check,
-- 0.4.61+) answered the adoption reference questions DOWNSTREAM only. A
-- stranger seat (ck-dev, 2026-09-04) walked into every one of them blind,
-- and a digest mis-citation (doctrine's file over the loader's bytes) was
-- sealed twice by independent authors before anything said so. Three moves,
-- one check body:
--
--   PRE   ckp._adoption_reference (NEW) rides instance.validate: the dry-run
--         answers sourceDigestMatch / moduleResolves / targetHasGraphs and
--         carries reference warnings — validate PREDICTS seal, new axis.
--   AT    the same checks ride the instance.create reply for an Adoption:
--         warnings + a `reference` object AT THE ACT. B4 throughout: reports,
--         never gates — refusal stays with the adopted obligation pair.
--   D-2   op_has_no_projector routes the adopter's intent (rule 19): the
--         hint and the registry teach now name instance.create of
--         core#Adoption + surface.declared + the dry-run.
--
-- Gate: s91 (PRE/AT with negative controls a+f; D-2 g+h). Generated from
-- sql/pgck-baseline.sql by scripts/gen-upgrade-from-baseline.sh — the two
-- delivery routes are the same bytes by construction.

-- D-2, data half: existing installs seeded teaches=NULL for this code; the
-- registry upserts on (code), so one idempotent UPDATE carries the route.
UPDATE ckp.refusal_registry
   SET teaches = 'the governed ops project SHAPE and LAW changes only. ADOPTION is not one of them: a module is adopted by sealing a core#Adoption through instance.create {type, adopts, intoProject, intoEpoch, sourceDigest} — learn the declared keys from surface.declared, take sourceDigest from the loader''s record (adoption.check: sourceRecorded), never from doctrine. Affordance registration is the op add_affordance'
 WHERE code = 'op_has_no_projector';
-- 0.4.112 — the ADOPTION REFERENCE CHECKS, one body serving two earlier moments
-- of the validation ladder (operator ruling 2026-09-04: "validation is cheap —
-- run it and know BEFORE you act"). The census (fleet.adoptions) and the
-- post-hoc audit (adoption.check) already run these three lookups DOWNSTREAM;
-- this function is the same checks exposed at PRE (instance.validate dry-run)
-- and AT (the seal reply's warnings). REPORTS, never gates (B4): a reference
-- failure warns; refusal remains the jurisdiction of the adopted obligations
-- (digest-match / adopts-resolves), by agreement, per kernel. Measured origin,
-- twice with independent authors: a wave Adoption citing the v3.12-dir file's
-- digest (doctrine) over the v3.11-dir bytes actually placed (f4ad27ce…) —
-- caught only downstream by adoption.check sourceDigestMatch:FALSE.
CREATE OR REPLACE FUNCTION ckp._adoption_reference(p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_adopts text := COALESCE(p_body->>(C||'adopts'), p_body->>'adopts');
  v_into   text := COALESCE(p_body->>(C||'intoProject'), p_body->>'intoProject');
  v_claim  text := COALESCE(p_body->>(C||'sourceDigest'), p_body->>'sourceDigest');
  v_has_src boolean := EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='pgrdf' AND table_name='_pgrdf_graphs' AND column_name='source_sha256');
  v_src text; v_resolves boolean; v_target boolean; v_match boolean;
  v_warn jsonb := '[]'::jsonb;
BEGIN
  -- No adopts IRI: nothing to judge — required-ness is the SHAPE's jurisdiction,
  -- and duplicating it here would be a second gate that can disagree with the first.
  IF v_adopts IS NULL THEN RETURN NULL; END IF;

  v_resolves := EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q
                  JOIN pgrdf._pgrdf_graphs g ON g.graph_id = q.graph_id
                 WHERE g.iri = v_adopts AND NOT q.is_inferred);
  IF v_has_src THEN
    SELECT g.source_sha256 INTO v_src FROM pgrdf._pgrdf_graphs g WHERE g.iri = v_adopts;
  END IF;
  v_match := CASE WHEN v_src IS NULL OR v_claim IS NULL THEN NULL ELSE (v_src = v_claim) END;
  IF v_into IS NULL THEN v_target := NULL;
  ELSE
    -- the SAME four-spelling reduction fleet.adoptions and _adopted_graphs use —
    -- a fifth implementation here would be a probe that tests the probe.
    v_target := EXISTS (SELECT 1 FROM pgrdf._pgrdf_graphs g3
      WHERE g3.iri LIKE 'urn:ckp:'
        || regexp_replace(
             regexp_replace(v_into, '^urn:ckp:project[:/]', ''),
             '^(urn:ckp:)?([^/]+)(/.*)?$', '\2')
        || '/%');
  END IF;

  IF NOT v_resolves THEN
    v_warn := v_warn || jsonb_build_object('check','moduleResolves','ok',false,
      'resultSeverity','sh:Warning',
      'resultMessage','the adopts IRI ('||v_adopts||') names NO non-empty graph in this store — sealed, this adoption composes NOTHING (the census''s malformed class). Place the module first (pgRDF plane, source_sha256 recorded at load); proximity is not adoption');
  END IF;
  IF v_match IS FALSE THEN
    v_warn := v_warn || jsonb_build_object('check','sourceDigestMatch','ok',false,
      'resultSeverity','sh:Warning',
      'resultMessage','the claimed sourceDigest does not match the loader''s record for these bytes (sourceRecorded '||v_src||') — doctrine wearing a digest. Cite the digest the loader measured, never a transcription; adoption.check explains per-module');
  ELSIF v_match IS NULL AND v_claim IS NOT NULL AND v_resolves THEN
    v_warn := v_warn || jsonb_build_object('check','sourceDigestMatch','ok',NULL,
      'resultSeverity','sh:Info',
      'resultMessage','no loader record exists for these bytes (loaded before recording, or via an unrecorded path) — the sourceDigest claim cannot be checked here. Null is this row''s history, not a pass');
  END IF;
  IF v_target IS FALSE THEN
    v_warn := v_warn || jsonb_build_object('check','targetHasGraphs','ok',false,
      'resultSeverity','sh:Warning',
      'resultMessage','intoProject ('||v_into||') reduces to a project segment with NO graphs in this store — this adoption would be reachable by no composed surface (the census''s orphaned class). Germinate or name the project that exists');
  END IF;

  RETURN jsonb_build_object(
    'sourceDigestMatch', v_match, 'sourceRecorded', v_src,
    'moduleResolves', v_resolves, 'targetHasGraphs', v_target,
    'warnings', v_warn);
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
  DECLARE v_viol jsonb; v_warn jsonb; v_ref jsonb;
  BEGIN
    SELECT COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IS DISTINCT FROM 'sh:Warning'
                                           AND r->>'resultSeverity' IS DISTINCT FROM 'sh:Info'), '[]'::jsonb),
           COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IN ('sh:Warning','sh:Info')), '[]'::jsonb)
      INTO v_viol, v_warn
      FROM jsonb_array_elements(COALESCE(v_report->'results', '[]'::jsonb)) r;
    -- 0.4.112 — PRE: the dry-run answers the REFERENCE questions too, for the
    -- one type whose failures were previously discoverable only downstream.
    -- Same checks the seal reply now carries (AT), so validate PREDICTS seal
    -- holds on the new axis exactly as it holds on shapes. conforms stays
    -- SHAPE-only: the seal does not refuse on reference either (B4), and a
    -- dry-run that predicted a refusal the seal does not make would be the
    -- split class this function exists to prevent.
    IF v_type = 'https://conceptkernel.org/ontology/v3.11/core#Adoption' THEN
      v_ref := ckp._adoption_reference(v_resolved);
      v_warn := v_warn || COALESCE(v_ref->'warnings', '[]'::jsonb);
    END IF;
    RETURN jsonb_build_object('ok', true, 'type', v_type,
      'conforms',   (jsonb_array_length(v_viol) = 0),
      'violations', v_viol,
      'warnings',   v_warn,
      'report',     v_report)
      || CASE WHEN v_ref IS NOT NULL THEN jsonb_build_object('reference', v_ref - 'warnings')
              ELSE '{}'::jsonb END;
  END;
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
  -- 0.4.112 — AT: for an Adoption, the reply answers the reference questions
  -- AT THE ACT (operator ruling 2026-09-04: everything needed is in the store
  -- at seal time — one cheap lookup each). WARNINGS, never a gate (B4): the
  -- seal stands; kernels that adopted the obligation pair get refusal there.
  DECLARE v_ref jsonb; v_warnout jsonb;
  BEGIN
    IF v_type = 'https://conceptkernel.org/ontology/v3.11/core#Adoption' THEN
      v_ref := ckp._adoption_reference(v_body);
    END IF;
    v_warnout := COALESCE(NULLIF(current_setting('ckp.last_warnings', true), '')::jsonb, '[]'::jsonb)
              || COALESCE(v_ref->'warnings', '[]'::jsonb);
    RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
      'verified', ckp.verify(v_iid),
      'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1))
      || ckp._stamped(v_iid)
      || CASE WHEN jsonb_array_length(v_warnout) > 0
              THEN jsonb_build_object('warnings', v_warnout)
              ELSE '{}'::jsonb END
      || CASE WHEN v_ref IS NOT NULL THEN jsonb_build_object('reference', v_ref - 'warnings')
              ELSE '{}'::jsonb END;
  END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
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
                              -- 0.4.112 (rule 19): a refusal that closes a route must OPEN the
                              -- intended one. Measured: a stranger seat read the six-op list and
                              -- was left with no next act — the closed world refused correctly
                              -- and taught nothing (USER-EXPERIENCE-PASS-5 D-2).
                              'hint', 'a governed op is refused at propose unless it can project a change (P0-E, pgCK#28). If your intent is ADOPTING A MODULE: adoption is not a governance op — seal a core#Adoption via instance.create (learn the declared keys from surface.declared; dry-run first with instance.validate, which now answers the reference questions too)',
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
  -- 0.4.107 (C-6): a project that sealed Memberships narrows who may propose.
  DECLARE
    v_tgt text := substring(v_about from '^urn:ckp:([a-z0-9-]+)/');
    v_me  text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_tgt IS NOT NULL AND NOT ckp._role_permits(v_tgt, 'urn:ckp:participant:'||ckp.urn_normalise(COALESCE(v_me,'')), 'propose') THEN
      RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
        'error', 'role_required', 'action', 'propose', 'project', v_tgt,
        'hint', 'this project seals Memberships, and yours (if any) holds no Role whose Grant carries permAction ''propose''. Roles narrow: ask the owner for a Membership, or propose against a project that has not narrowed itself.');
    END IF;
  END;

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

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
