-- pgck 0.4.62 — quorum is distinct accountable parties; the dry-run candidate
-- is the seal's candidate; the inbox hears every spelling of your name.
--
-- (1) QUORUM (ck-dev's finding-1786732252462817000): approvals counted VOTES —
-- one identity twice was two approvals — and ckp.seal mints a fresh anon uuid
-- per unattributed call, so a psql caller could manufacture any quorum. Now:
-- count(DISTINCT createdBy), anon:* excluded. An identity nobody can be held
-- to cannot be a party to a decision. Refusing unattributed seals outright is
-- the destination (operator paths will name a declared service identity); that
-- lands with the test migration, and this closes the exploit today.
-- (2) VALIDATE ⟺ SEAL (ck-dev's operation-1786642612862085000): the dry-run
-- serialized the body alone, so parent-closure requirements were invisible —
-- wave:Pass ⊑ ckp:Epoch demands epoch+surfaceDigest at seal while validate
-- said conforms:true without them. The dry-run candidate now composes all
-- three parts exactly as seal does: body + parent closure + derived stamps.
-- (3) ORACLE INBOX: opTarget matched only the wave alias; ck-dev's two
-- escalations to urn:ckp:pgck/kernel sat unseen for a day. All three
-- spellings match now — the intoProject lesson, applied to addressing.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

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
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 1);
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
    PERFORM ckp.seal('epoch-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Epoch', '@id', v_eiri,
      C||'epoch', to_jsonb(v_epoch),
      C||'surfaceDigest', v_surfd));
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
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}}. NOT accepted: @type (never read), or {"type": …, "body": {…}} — that puts the type outside the body this verb descends into.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
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
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'detail', SQLERRM);
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

  RETURN jsonb_build_object('ok', true, 'type', v_type,
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb),
    'report',     v_report);
END;
$function$
;

-- 0.4.58 — THE ORACLE (v3.12 §5, first built piece). Signals are DERIVED from
-- sealed facts, never asserted; the pass boundary is a query, never a memory.
--
-- The question it answers: WHAT GOES ON THIS PASS, AND WHAT GOES ON THE NEXT?
-- The rule, encoded rather than remembered:
--   THIS pass  = facts stamped with its number (discoveredAtPass / resolvedAtPass
--                / ruledAtPass / opAtPass / rebasedAtPass / forPass), plus the
--                epochs those acts advanced. Closed when its Index is sealed and
--                its Confirmations reference re-run gates.
--   NEXT pass  = whatever `next` returns AT INDEX-SEAL TIME: open findings,
--                pending unretired proposals, operations addressed to this
--                component and not yet answered. Nobody decides the carry-over
--                by memory; the queue IS the derivation.
--   THIS wave  = everything bound to one root digest (wave:Statement bindsRoot).
--                The NEXT wave begins when the root moves — never mid-root.
--
-- Facts are relational (sealed instances), so this is a built-in, not a SPARQL
-- affordance — the F20 limit, stated by pgck-mcp: sealed instances are not in
-- RDF yet. When stamp projection lands, each signal becomes a governed SPARQL
-- read and this function retires into compatibility.
CREATE OR REPLACE FUNCTION ckp.wave_oracle(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  W text := 'https://conceptkernel.org/ontology/v3.11/wave#';
  v_proj  text := ckp._project();
  v_pass  int  := (p_payload->>'pass')::int;
  -- component alias convention: c-<project, dashes stripped> (c-pgck, c-pgckmcp);
  -- override with {component} where the convention doesn't hold (ck-lib-js → c-cklib).
  v_comp  text := COALESCE(p_payload->>'component', W||'c-'||replace(v_proj,'-',''));
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
  v_this jsonb; v_next jsonb; v_sig jsonb;
BEGIN
  -- THIS PASS — everything stamped with the number, any of the six stamps.
  IF v_pass IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'type', regexp_replace(i.body->>'type','^.*[/#]',''),
        'by',   i.body->>(C||'producedBy'),
        'judged', (i.body ? (C||'conformsToShape'))) ORDER BY i.ts_created), '[]'::jsonb)
      INTO v_this
    FROM ckp.instances i
    WHERE COALESCE((i.body->>(W||'discoveredAtPass'))::numeric, -1) = v_pass
       OR COALESCE((i.body->>(W||'resolvedAtPass'))::numeric,  -1) = v_pass
       OR COALESCE((i.body->>(W||'ruledAtPass'))::numeric,     -1) = v_pass
       OR COALESCE((i.body->>(W||'opAtPass'))::numeric,        -1) = v_pass
       OR COALESCE((i.body->>(W||'rebasedAtPass'))::numeric,   -1) = v_pass
       OR i.body->>(W||'forPass') = W||'pass-'||v_pass;
  END IF;

  -- THE NEXT-PASS QUEUE — derived, so carry-over is never a memory exercise.
  v_next := jsonb_build_object(
    'openFindings', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'label', left(COALESCE(i.body->>'http://www.w3.org/2000/01/rdf-schema#label',
                               i.body->>(W||'label')), 140),
        'by', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Finding' AND i.body->>(W||'findingState') = 'open'),
    'pendingProposals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'about', i.body->>(C||'about'), 'op', i.body->>(C||'proposalOp'),
        'by', i.body->>(C||'createdBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = C||'Proposal'
        AND i.body->>(C||'proposalState') = 'pending'
        AND NOT i.body ? (C||'retiredAtEpoch')),
    'inbox', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'opKind', i.body->>(W||'opKind'),
        'from', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Operation'
        -- 0.4.62: opTarget has no canonical spelling — components address this
        -- kernel as its wave alias, its kernel URN, or its kernel/ck graph. Two
        -- escalations from ck-dev sat unseen for a day because this matched the
        -- alias alone. Same defect family as the intoProject spellings.
        AND i.body->>(W||'opTarget') IN (v_comp,
              'urn:ckp:'||v_proj||'/kernel', 'urn:ckp:'||v_proj||'/kernel/ck')));

  -- SIGNALS — health counts a third party can recompute. Never one boolean.
  v_sig := jsonb_build_object(
    'unjudged',       (SELECT count(*) FROM ckp.instances i
                       WHERE COALESCE((i.body->>(C||'sealedAtEpoch'))::numeric, -1) >= 1
                         AND NOT i.body ? (C||'conformsToShape')),
    'preEnforcement', (SELECT count(*) FROM ckp.instances i
                       WHERE NOT i.body ? (C||'sealedAtEpoch')),
    'anonymousSeals', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>(C||'createdBy') LIKE 'urn:ckp:participant:anon%'),
    'openFindings',   (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = W||'Finding'
                         AND i.body->>(W||'findingState') = 'open'),
    'pendingProposalsFleet', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = C||'Proposal'
                         AND i.body->>(C||'proposalState') = 'pending'
                         AND NOT i.body ? (C||'retiredAtEpoch')));

  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj, 'component', v_comp, 'epoch', v_epoch,
    'pass', v_pass, 'thisPass', COALESCE(v_this, '[]'::jsonb),
    'next', v_next, 'signals', v_sig,
    'boundary', 'THIS pass = facts stamped with its number + the epochs they advanced; closed at Index seal. NEXT pass = this `next` object AT close — derived, never remembered. NEXT wave = when bindsRoot moves. unjudged means sealedAtEpoch>=1 with conformsToShape ABSENT: admitted, ledgered, judged by nothing — the fence.');
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
