-- pgck--0.4.84--0.4.85.sql — WHAT WAS GOVERNED IN SHOWS UP IN ITS OWN LIST
-- (pgCK#56 closed on the loop form; HANDOVER B5; suite cases 04 + 28).
--
-- apply compiled the plan and inserted the registry row — callable — and sealed
-- NO ckp:Affordance, so capability worked while its declared face was absent
-- and the affordances list stayed empty of it forever (the declared/routed gap,
-- measured since PASS-25). Emission and declaration now move in ONE act: both
-- registrars (query + derived) seal the ckp:Affordance in the same transaction
-- as the registry row — gated by AffordanceShape, producedBy the kernel's law,
-- derivedBy the Materialization the same apply sealed, plane in the ROOT's
-- closed vocabulary ('derived'; the registry's plane column stays routing
-- truth). A seal refusal fails the apply loudly: a capability that cannot
-- declare itself does not go live half-made.
--
-- GENERATED from the baseline bytes — both roads carry identical statements.


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
  -- out_topic DECLARES where the caller will receive the result. It was left
  -- NULL on every row (0 of 30 measured), so a subscriber had no way to know
  -- what to listen to. This is not a new channel: src/nats_client.rs already
  -- publishes replies to result.kernel.<kernel>.<verb>. Registration now
  -- states the truth the transport already implements.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, out_topic, plane, epoch)
  VALUES (p_project, v_verb, 'input.kernel.'||p_project||'.action.'||v_verb,
          'result.kernel.'||p_project||'.'||v_verb, 'query', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'query', epoch = EXCLUDED.epoch,
    out_topic = EXCLUDED.out_topic, refreshed_at = now();

  -- 0.4.85 (#56 / HANDOVER B5) — EMISSION AND DECLARATION MOVE IN ONE ACT. The
  -- registry row makes the verb callable; this seal makes it a FACT: a
  -- ckp:Affordance gated by AffordanceShape, producedBy this kernel's law,
  -- derivedBy the Materialization this very apply sealed. The sealed plane is
  -- the ROOT's vocabulary ('derived' — the shape's closed set); the registry's
  -- plane column stays routing truth. A refusal here fails the apply loudly —
  -- a capability that cannot declare itself does not go live half-made.
  PERFORM ckp.seal('aff-'||p_project||'-'||replace(v_verb,'.','-'), jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Affordance',
    '@id',  'ckp://Affordance#'||p_project||'.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#inTopic',
      'input.kernel.'||p_project||'.action.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#outTopic',
      'result.kernel.'||p_project||'.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#plane', 'derived',
    'https://conceptkernel.org/ontology/v3.11/core#derivedBy',
      format('urn:ckp:%s/materialization/%s', p_project, p_epoch)));

  RETURN v_verb;
END;
$function$
;

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
  -- out_topic DECLARES where the caller will receive the result. It was left
  -- NULL on every row (0 of 30 measured), so a subscriber had no way to know
  -- what to listen to. This is not a new channel: src/nats_client.rs already
  -- publishes replies to result.kernel.<kernel>.<verb>. Registration now
  -- states the truth the transport already implements.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, out_topic, plane, epoch)
  VALUES (p_project, v_verb, 'input.kernel.'||p_project||'.action.'||v_verb,
          'result.kernel.'||p_project||'.'||v_verb, 'derived', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'derived', epoch = EXCLUDED.epoch,
    out_topic = EXCLUDED.out_topic, refreshed_at = now();

  -- 0.4.85 (#56 / HANDOVER B5) — EMISSION AND DECLARATION MOVE IN ONE ACT. The
  -- registry row makes the verb callable; this seal makes it a FACT: a
  -- ckp:Affordance gated by AffordanceShape, producedBy this kernel's law,
  -- derivedBy the Materialization this very apply sealed. The sealed plane is
  -- the ROOT's vocabulary ('derived' — the shape's closed set); the registry's
  -- plane column stays routing truth. A refusal here fails the apply loudly —
  -- a capability that cannot declare itself does not go live half-made.
  PERFORM ckp.seal('aff-'||p_project||'-'||replace(v_verb,'.','-'), jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Affordance',
    '@id',  'ckp://Affordance#'||p_project||'.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#inTopic',
      'input.kernel.'||p_project||'.action.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#outTopic',
      'result.kernel.'||p_project||'.'||v_verb,
    'https://conceptkernel.org/ontology/v3.11/core#plane', 'derived',
    'https://conceptkernel.org/ontology/v3.11/core#derivedBy',
      format('urn:ckp:%s/materialization/%s', p_project, p_epoch)));

  RETURN v_verb;
END;
$function$
;
