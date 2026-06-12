-- ============================================================================
-- pgck 0.4.6 -> 0.4.7 — Tier 2 (3/3b): governed query affordances (concept.match form)
-- ============================================================================
-- v3.9 §6.3: where a kernel needs a richer read than QueryShape composition, it declares
-- a GOVERNED query affordance — the SPARQL text is authored once, sealed as part of the
-- kernel via the governance plane (propose -> vote -> apply), compiled at apply-time, and
-- exposed under a verb name with a typed parameter shape. Callers bind parameters; they
-- never see, choose, or alter the query text. This is the only sanctioned "SPARQL
-- affordance for clients" — never raw passthrough.
--
-- This also makes the previously-vestigial plan compiler load-bearing: the sealed query is
-- stored in ckp.plans keyed by (kernel, verb, epoch) — exactly §5.3's "compiled query
-- templates" — and runtime dispatch binds typed params into it.
--
--   1. propose_change op=add_affordance, detail={verb, query, params:[…]}  -> sealed Proposal
--   2. vote -> quorum
--   3. apply -> ckp.register_query_affordance: compile the query into ckp.plans(kernel,verb,
--      epoch) + add a plane='query' affordance_registry row, in the apply txn (governed fact)
--   4. dispatch(verb, {param: value, …}) -> ckp.run_query_affordance: validate + bind the
--      caller's param VALUES into the sealed query text, run it, return rows
--
-- Injection safety is layered: the query text is a sealed governance fact (consensus-authored,
-- never caller input); param NAMES are gated at registration; param VALUES are gated at bind
-- time (no quote/brace/backslash/?-var can reach the query) and substituted into the author's
-- `$param$` placeholders (which the governed query places in string-literal positions).
--
-- Exit test: sql/test/s41_governed_query_affordance.sql — govern-add a `demo.search` label
-- query, dispatch it with a bound term (returns the matching instance), and confirm a caller
-- cannot pass raw query text and an injection-shaped param value is rejected.
-- ============================================================================

-- ---- ckp.register_query_affordance — compile a sealed query at apply-time ----
CREATE OR REPLACE FUNCTION ckp.register_query_affordance(p_prop jsonb, p_project text, p_epoch int)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $rqa$
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
  VALUES ('pgCK', v_verb, p_epoch,
          jsonb_build_object('kind', 'sparql', 'statement', v_query, 'params', v_params))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='query'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES ('pgCK', v_verb, 'input.kernel.pgCK.action.'||v_verb, 'query', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'query', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$rqa$;
ALTER FUNCTION ckp.register_query_affordance(jsonb, text, int) OWNER TO ck_substrate;

-- ---- ckp.run_query_affordance — validate + bind caller params, run the sealed query ----
CREATE OR REPLACE FUNCTION ckp.run_query_affordance(p_verb text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $run$
DECLARE
  v_plan   jsonb;
  v_stmt   text;
  v_params jsonb;
  v_val_re text := '^[A-Za-z0-9 ._:#/-]*$';   -- param VALUE gate: no quote/brace/backslash/?-var
  v_name   text;
  v_val    text;
  v_rows   jsonb;
BEGIN
  -- latest-epoch plan for this governed verb (a stale epoch is simply superseded).
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel = 'pgCK' AND verb = p_verb ORDER BY epoch DESC LIMIT 1;
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
$run$;
ALTER FUNCTION ckp.run_query_affordance(text, jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.run_query_affordance(text, jsonb) IS
  'Tier 2 (3/3b): run a governed query affordance — look up the sealed (kernel,verb,epoch) plan, '
  'validate + bind the caller''s typed param VALUES into the author''s $name$ placeholders, run. '
  'The SPARQL text is a sealed governance fact; callers never supply query text.';

-- ---- ckp.apply — register query affordances (step 4c), alongside graph-apply (4a) ----
CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $apply$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_about     text := p_payload->>'about';
  v_proj      text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
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

  -- 4b. CASCADE — _recompile + epoch advance.
  v_epoch := ckp.bump_epoch('pgCK');

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
$apply$;
ALTER FUNCTION ckp.apply(jsonb) OWNER TO ck_substrate;

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
