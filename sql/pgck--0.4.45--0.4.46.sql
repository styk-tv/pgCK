-- pgck 0.4.46 — a governed change that projects nothing is refused, not sealed
--
-- MEASURED on pgck.localhost while sealing the first integrity-check affordance.
--
-- 1. THE INERT EPOCH (the serious one). P0-E states: "an op that cannot project
--    a change is refused HERE, at propose -- never sealed as an inert 'applied'
--    that bumps the epoch and changes nothing." The guard checked that the OP
--    had a projector and never that the DETAIL carried anything to project. An
--    add_affordance with an empty detail therefore sealed applied, bumped the
--    epoch, registered nothing, and returned ok:true with graph_changed:false
--    and no error on any surface. pgck epoch 5 IS that inert applied -- an epoch
--    that logged nothing while reporting success. Now refused at propose.
--
-- 2. `detail` IN, `proposalDetail` OUT. propose_change read p_payload->'detail';
--    apply reads v_prop->'proposalDetail'. A caller using the name it reads back
--    silently got {} -- which is how (1) was reached. Both spellings accepted.
--
-- 3. `about` DEFAULTED TO A BARE SEGMENT. ckp.dispatch calls
--    propose_change(v_proj, ...) where v_proj is 'pgck', not a URN, despite the
--    parameter being named p_kernel_urn. ProposalShape demands sh:IRI, so every
--    proposal omitting `about` was refused with a NodeKind violation naming a
--    literal. The refusal was correct and useful; the default was not.
--
-- 4. vote read only 'value' while VoteShape declares ckp:voteValue -- the
--    declared name returned invalid_vote_value. Both accepted.
--
-- 5. THE REGISTRARS IGNORED THEIR OWN PARAMETER. register_query_affordance and
--    register_derived_affordance take p_project and inserted a hard-coded kernel
--    literal into ckp.plans and ckp.affordance_registry, so every kernel's query
--    affordances would register under one name. 0.4.45 corrected the literal's
--    VALUE; this corrects the STRUCTURE. No kernel name belongs in a function
--    that was handed one.
--
-- 6. AND THE READERS. Fixing the registrars alone SPLIT THE PAIR: the write
--    landed under the calling project while run_query_affordance /
--    run_derived_affordance still read ckp.plans under a hard-coded kernel, so
--    a governed query registered fine and then resolved to unknown_affordance.
--    smoke-s4 caught it at s41 (project 's41-test'), which had been passing only
--    because writer and reader were hard-coded to the SAME wrong literal.
--    ckp.apply read one kernel's epoch while bumping another's, and
--    concept_match read its plan the same way. All resolve the project now.
--
--    No ckp FUNCTION names a kernel any more. The registry SEED still does --
--    install runs before any kernel exists, so it has nothing else to name.
--    That is the substrate-floor question, not this migration's.
--
-- 7. PLAN RESOLUTION IS TWO-LAYERED, and it has to be. Reading plans under the
--    calling project alone made the SEEDED substrate verbs unreachable for every
--    project (smoke-s4 s32: concept.match is seeded at install and belongs to no
--    kernel, because install runs before any kernel exists). Reading them under
--    one fixed kernel alone made every project share that kernel's plans. So:
--    the calling project's plan wins, and the seeded floor is the fallback.
--    That is the substrate-floor split, made concrete in one ORDER BY.
--
-- 8. ckp.dispatch RESOLVED EVERY KERNEL'S AFFORDANCES UNDER ONE NAME:
--       v_aff := ckp.registry_lookup('pgck', v_canon);
--    A verb registered by any other kernel was invisible, so every non-pgck
--    workspace got unknown_affordance. It looked correct only because the seed
--    and the registrars were hard-coded to the SAME literal -- writer and reader
--    wrong in the same direction, which is not agreement, only symmetry.
--    registry_lookup is now two-layered like ckp.plans: the caller's own row
--    wins, the seeded floor is the fallback.
--
-- 9. ckp.apply BUMPED A FIXED KERNEL'S EPOCH on every apply by anyone, so every
--    other kernel's epoch never advanced and its plans were recompiled under a
--    name it does not own.
--
-- 10. ONE PROJECT RESOLVER. Thirteen sites resolved "which project is this"
--     inline, in two spellings that disagreed on the empty string: dispatch
--     mapped '' to '', everything else to 'demo' -- so an empty GUC sent the
--     lookup and the write to different kernels. All now call ckp._project().
--     The 'demo' fallback is a real kernel name and therefore a landing site
--     for unattributed writes; it now exists in exactly one place and can be
--     made fail-closed in one edit.


CREATE OR REPLACE FUNCTION ckp._project()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  -- ONE definition of "which project is this". Twelve call sites resolved it
  -- inline in two spellings that DISAGREED on the empty string: ckp.dispatch
  -- mapped '' to '', everything else mapped '' to 'demo' -- so an empty GUC
  -- sent the affordance lookup and the write to different kernels.
  --
  -- The 'demo' fallback is itself a real kernel name, which makes it a landing
  -- site for writes that belong to nobody. It lives HERE now, in one place, so
  -- it can be made fail-closed in a single edit instead of twelve.
  SELECT COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
$function$;
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
                                'error', 'verb not governed yet (CI-B): ' || p_verb);
  END CASE;
  RETURN res || jsonb_build_object('kernel', p_kernel_urn);
END;
$function$;

CREATE OR REPLACE FUNCTION ckp.registry_lookup(p_kernel text, p_verb text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  -- EMPTY MEANS NONE. A kernel is authorized for the verbs its OWN registry
  -- rows name. It is never authorized for another kernel's, and never for
  -- EVERYTHING on the grounds that it has none -- degrading an empty surface
  -- to the full surface is fail-open authorization (d-28-sah-1). All 26 seeded
  -- rows name kernel pgCK, so every other workspace resolves to zero rows,
  -- which is a true answer meaning none.
  --
  -- ONE bootstrap exception, the narrowest that still permits creation: a
  -- kernel that does not exist yet cannot own a registry row, so without this
  -- no kernel could ever be created through the door. kernel.germinate is the
  -- only verb reachable with no surface -- it refuses anonymous callers and
  -- stamps ownedBy from the verified connection, so reaching it proves an
  -- identity rather than bypassing one.
  -- YOUR OWN FIRST, THEN THE SUBSTRATE FLOOR. A row this kernel registered wins;
  -- otherwise the row seeded at install, which belongs to no kernel because
  -- install runs before any kernel exists. Resolving ONLY the floor made every
  -- kernel share one name's surface; resolving ONLY the caller made the seeded
  -- verbs unreachable for everyone. Empty still means NONE -- it is now a real
  -- answer about this kernel rather than a lookup under someone else's name.
  SELECT to_jsonb(r) FROM ckp.affordance_registry r
  WHERE r.verb = p_verb
    AND (r.kernel = p_kernel OR r.kernel = 'pgck' OR p_verb = 'kernel.germinate')
  ORDER BY (r.kernel = p_kernel) DESC
  LIMIT 1;
$function$;

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
  -- not editing the list.
  v_ops    text[] := ARRAY['add_class','add_property','set_transition_map','add_affordance'];
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
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'op', v_op,
        'hint', 'add_affordance needs detail.verb and detail.query; without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_has_no_projector', 'op', v_op,
                              'hint', 'a governed op is refused at propose unless it can project a change (P0-E, pgCK#28)',
                              'allowed', to_jsonb(v_ops));
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  BEGIN
    v_quorum := COALESCE((p_payload->>'requires_quorum')::int, 1);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum',
                              'value', p_payload->>'requires_quorum');
  END;
  IF v_quorum < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'value', v_quorum);
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
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'violations', v_report->'violations');
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
$function$;

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

  -- 5. quorum check: COUNT approve-votes about this Proposal vs requiresQuorum.
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote'
      AND body->>(C||'about') = v_about
      AND body->>(C||'voteValue') = 'approve';

  RETURN jsonb_build_object('ok', true, 'vote', v_vid, 'proposal', v_about, 'value', v_value,
                            'approvals', v_approvals, 'quorum', v_quorum,
                            'quorum_met', v_approvals >= v_quorum, 'verified', ckp.verify(v_vid));
END;
$function$;

CREATE OR REPLACE FUNCTION ckp.register_query_affordance(p_prop jsonb, p_project text, p_epoch integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_detail  jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_verb    text  := v_detail->>'verb';
  v_query   text  := v_detail->>'query';
  v_params  jsonb := COALESCE(v_detail->'params', '[]'::jsonb);
  v_name_re text  := '^[a-z][a-z0-9_.]*$';   -- verb + param NAME gate (lowercase dotted ids)
  v_p       text;
BEGIN
  IF v_verb IS NULL OR v_verb !~ v_name_re THEN
    RAISE EXCEPTION 'add_affordance: verb must be a safe dotted name, got %', v_verb; END IF;
  IF v_query IS NULL OR length(btrim(v_query)) < 1 THEN
    RAISE EXCEPTION 'add_affordance: query text required'; END IF;
  IF jsonb_typeof(v_params) <> 'array' THEN
    RAISE EXCEPTION 'add_affordance: params must be a JSON array of names'; END IF;
  FOR v_p IN SELECT jsonb_array_elements_text(v_params) LOOP
    IF v_p !~ v_name_re THEN RAISE EXCEPTION 'add_affordance: unsafe param name %', v_p; END IF;
  END LOOP;

  -- COMPILE: the sealed query becomes the plan for (kernel, verb, epoch). §5.3 made real.
  INSERT INTO ckp.plans(kernel, verb, epoch, plan)
  VALUES (p_project, v_verb, p_epoch,
          jsonb_build_object('kind', 'sparql', 'statement', v_query, 'params', v_params))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='query'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES (p_project, v_verb, 'input.kernel.'||p_project||'.action.'||v_verb, 'query', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'query', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$function$;

CREATE OR REPLACE FUNCTION ckp.register_derived_affordance(p_prop jsonb, p_project text, p_epoch integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_detail  jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_verb    text  := v_detail->>'verb';
  v_formula text  := v_detail->>'formula';
  v_scope   jsonb := v_detail->'scope';
  v_name_re text  := '^[a-z][a-z0-9_.]*$';
BEGIN
  IF v_verb IS NULL OR v_verb !~ v_name_re THEN
    RAISE EXCEPTION 'add_derived_affordance: verb must be a safe dotted name, got %', v_verb; END IF;
  IF v_formula IS NULL OR length(btrim(v_formula)) < 1 THEN
    RAISE EXCEPTION 'add_derived_affordance: formula required'; END IF;
  IF v_scope IS NULL OR v_scope->>'type' IS NULL OR v_scope->>'about_prop' IS NULL THEN
    RAISE EXCEPTION 'add_derived_affordance: scope {type, about_prop} required'; END IF;

  -- COMPILE: the sealed {formula, scope} becomes the plan for (kernel, verb, epoch).
  INSERT INTO ckp.plans(kernel, verb, epoch, plan)
  VALUES (p_project, v_verb, p_epoch,
          jsonb_build_object('kind', 'derived', 'formula', v_formula, 'scope', v_scope))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='derived'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES (p_project, v_verb, 'input.kernel.'||p_project||'.action.'||v_verb, 'derived', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'derived', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$function$;

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
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_query_affordance', 'verb', p_verb); END IF;

  v_stmt   := v_plan->>'statement';
  v_params := COALESCE(v_plan->'params', '[]'::jsonb);

  -- bind each declared param: the caller supplies a VALUE only; validate it, then substitute
  -- into the author's `$name$` placeholder (placed in string-literal positions by the query).
  FOR v_name IN SELECT jsonb_array_elements_text(v_params) LOOP
    v_val := p_payload->>v_name;
    IF v_val IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'param', v_name); END IF;
    IF v_val !~ v_val_re THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'param', v_name); END IF;
    v_stmt := replace(v_stmt, '$' || v_name || '$', v_val);
  END LOOP;

  -- run the GOVERNED query — the text is a sealed kernel fact; only validated values were bound.
  SELECT jsonb_agg(j) INTO v_rows FROM pgrdf.sparql(v_stmt) j;
  RETURN jsonb_build_object('ok', true, 'verb', p_verb,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'rows', COALESCE(v_rows, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

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
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_derived_affordance', 'verb', p_verb); END IF;
  IF v_concept IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'param', 'concept'); END IF;
  IF v_concept !~ v_val_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'param', 'concept'); END IF;

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
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

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
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
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
$function$;

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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'term', v_term);
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
$function$;
