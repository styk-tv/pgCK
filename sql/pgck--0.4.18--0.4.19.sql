-- pgck 0.4.18 -> 0.4.19 — governed DERIVED-read dispatch plane (scoring-loop layer 3).
--
-- The ε-materialize substrate (v0.4.16/17) shipped ckp.derived_sum/derived_dispersion as ckp.*
-- SQL functions, but they were NOT reachable through ckp.dispatch — so a role-floor client
-- (ck_participant, dispatch-only) could not get a score. This adds a GENERIC `plane='derived'`
-- affordance, exactly parallel to the `plane='query'` one: a consumer seals a {formula, scope}
-- verb via governance (propose -> vote -> apply); dispatch routes it to ckp.run_derived_affordance,
-- which binds the caller's `concept` and runs the (e1) synchronous derived read, returning the
-- BAND-LESS envelope {ok, value, scored, freshness}. The verb NAME + formula + any bands are the
-- CONSUMER's sealed fact — no consumer term lives here (the substrate stays generic + band-less).

-- ---- ckp.register_derived_affordance — seal a {formula, scope} verb at apply-time ----
-- Mirrors register_query_affordance: compile into ckp.plans(kernel,verb,epoch) + a plane='derived'
-- affordance_registry row. The formula is a sealed governance fact (same trust model as the sealed
-- SPARQL of a query affordance); callers never supply formula text.
CREATE OR REPLACE FUNCTION ckp.register_derived_affordance(p_prop jsonb, p_project text, p_epoch int)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $rda$
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
  VALUES ('pgCK', v_verb, p_epoch,
          jsonb_build_object('kind', 'derived', 'formula', v_formula, 'scope', v_scope))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='derived'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES ('pgCK', v_verb, 'input.kernel.pgCK.action.'||v_verb, 'derived', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'derived', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$rda$;
ALTER FUNCTION ckp.register_derived_affordance(jsonb, text, int) OWNER TO ck_substrate;

-- ---- ckp.run_derived_affordance — bind the caller's concept, run the sealed derived read ----
-- The caller supplies only the CONCEPT (validated); the formula + scope template are the sealed
-- kernel fact. (e1) synchronous: ckp.derived_sum materializes-if-stale then SUM(:contrib). Returns
-- the band-less envelope; `freshness` reports the phenotype watermark vs the current evidence
-- watermark so an honest client can see staleness (the (e2) over-budget recompute_in_progress
-- path is the same envelope discriminator, surfaced by the substrate when a budget is exceeded).
CREATE OR REPLACE FUNCTION ckp.run_derived_affordance(p_verb text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $run$
DECLARE
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
    WHERE kernel = 'pgCK' AND verb = p_verb ORDER BY epoch DESC LIMIT 1;
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
$run$;
ALTER FUNCTION ckp.run_derived_affordance(text, jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.run_derived_affordance(text, jsonb) IS
  'Scoring-loop layer 3: run a governed derived-read affordance — look up the sealed (kernel,verb,'
  'epoch) {formula, scope}, bind the caller''s concept, run ckp.derived_sum (e1 synchronous), return '
  'the band-less envelope {ok, value, scored, freshness}. Generic: verb name + formula + bands are '
  'the consumer''s sealed fact, not substrate code.';
