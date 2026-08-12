-- pgck 0.4.49 — the push chain names the kernel that produced the fact
--
-- Measured on the bench while chasing "subscribers see messages in the browser":
--     ckp.outbox                    0 rows      (drain works, trigger fires)
--     registry out_topic populated  0 of 30
--     sealed Affordance outTopic    0 of 5
--     compute_publish_subject       'event.kernel.pgck.%s.sealed'   <- a literal
--     by header                     urn:ckp:board/created_by  (5 rows carry it;
--                                                              73 carry core createdBy)
--
-- 1. EVERY KERNEL PUBLISHED TO ONE SUBJECT. compute_publish_subject hard-coded
--    the kernel segment, so a browser subscribed to event.kernel.<its-own>.*
--    received nothing while the publish reported success. Same defect as
--    dispatch resolving every caller under one name (0.4.46/47), on the
--    OUTBOUND path -- where it is harder to see, because a publish to a subject
--    nobody listens on fails silently and looks identical to "no events yet".
--
--    The kernel is derived from the SEALED producedBy stamp
--    (urn:ckp:<project>/kernel/ck), not session state, which by trigger time may
--    belong to a different caller. Added as a DEFAULT parameter rather than a
--    second overload: three of today's defects were an overload pair drifting,
--    and one CREATE with a default cannot drift. STABLE rather than IMMUTABLE,
--    since it consults ckp._project() when not told.
--
-- 2. `by` WAS ABSENT ON VIRTUALLY EVERYTHING. The header keyed only on the
--    v3.8-era urn:ckp:board/created_by. After 0.4.44 the derived stamp is
--    ckp:createdBy in core, so 73 of 78 instances published with no sender at
--    all -- and "who said what" is the entire point of a message a peer can
--    trust. Reads the core stamp first, board form as legacy fallback. The
--    value stays unforgeable because createdBy derives from the verified
--    connection.
--
-- 3. out_topic DECLARED NOTHING. Left NULL on every row, so a subscriber had no
--    way to know what to listen to. This adds no channel: src/nats_client.rs
--    already publishes replies to result.kernel.<kernel>.<verb>. Registration
--    now states the truth the transport already implements, which is what makes
--    it discoverable through `affordances` instead of by reading Rust.

-- DROP THE 1-ARG OVERLOAD FIRST. Adding a DEFAULT parameter does not replace
-- ckp.compute_publish_subject(text) -- it CREATES a second function beside it,
-- and a one-argument call then either resolves to the old hard-coded one or is
-- rejected as ambiguous. This is the same overload hazard that shipped the wrong
-- dispatch in 0.4.47 and split _body_to_ttl before it; the DEFAULT that was
-- supposed to prevent a pair is exactly what creates one here.
DROP FUNCTION IF EXISTS ckp.compute_publish_subject(text);

CREATE OR REPLACE FUNCTION ckp.compute_publish_subject(p_type_uri text, p_project text DEFAULT NULL)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  -- The subject names the kernel that PRODUCED the fact. This was
  -- 'event.kernel.pgck.%s.sealed' -- a literal -- so every kernel's events
  -- landed on one subject and a browser subscribed to its own kernel saw
  -- nothing. Same defect as dispatch resolving every caller under one name
  -- (0.4.46/47), on the OUTBOUND path, where it is invisible from inside:
  -- the publish succeeds, it just arrives somewhere nobody is listening.
  --
  -- DEFAULT rather than a second overload: three of today's defects were an
  -- overload pair drifting apart, and one CREATE with a default cannot.
  -- STABLE, not IMMUTABLE -- it depends on ckp._project() when not told.
  SELECT format(
    'event.kernel.%s.%s.sealed',
    COALESCE(NULLIF(p_project, ''), ckp._project()),
    COALESCE(
      NULLIF(regexp_replace(COALESCE(p_type_uri, ''), '^.*[/#]', ''), ''),
      'Instance'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION ckp.ledger_to_outbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_body JSONB;
  v_proj TEXT;
BEGIN
  SELECT body INTO v_body FROM ckp.instances WHERE id = NEW.instance_id;
  IF v_body IS NULL THEN
    -- ledger row without a matching instance row should not happen
    -- (ckp.seal() inserts instance before ledger); skip rather than fail
    RETURN NEW;
  END IF;

  -- The producing kernel comes from the SEALED producedBy stamp
  -- (urn:ckp:<project>/kernel/ck) -- substrate-derived and unforgeable -- not
  -- from session state, which by trigger time may belong to another caller.
  v_proj := NULLIF(regexp_replace(
              COALESCE(v_body->>'https://conceptkernel.org/ontology/v3.11/core#producedBy',''),
              '^urn:ckp:(.*)/kernel/ck$', '\1'), '');
  IF v_proj IS NULL OR v_proj = v_body->>'https://conceptkernel.org/ontology/v3.11/core#producedBy' THEN
    v_proj := ckp._project();
  END IF;

  INSERT INTO ckp.outbox(ledger_seq, subject, payload, headers)
  VALUES (
    NEW.seq,
    ckp.compute_publish_subject(v_body->>'type', v_proj),
    convert_to(v_body::text, 'UTF8'),
    jsonb_build_object(
      'Ck-Seq',        NEW.seq::text,
      'Content-Type',  'application/json'
    )
    -- F4 (msg.by): stamp the server-attributed sender `by` so peers (kernels, web bots, users) see
    -- who-said-what WITHOUT the client asserting it. `created_by` derives from the VERIFIED
    -- ckp.requester (F-A), never a client field — so `by` is un-forgeable.
    -- `by` reads the DERIVED core stamp first. It keyed only on the v3.8-era
    -- board property, which 5 instances carry against 73 with core createdBy --
    -- so after the 0.4.44 identity work the header was absent on virtually
    -- everything, and a subscriber could not tell who said what. Board form
    -- kept as the legacy fallback.
    || CASE WHEN v_body ? 'https://conceptkernel.org/ontology/v3.11/core#createdBy'
            THEN jsonb_build_object('by', v_body->>'https://conceptkernel.org/ontology/v3.11/core#createdBy')
            WHEN v_body ? 'urn:ckp:board/created_by'
            THEN jsonb_build_object('by', v_body->>'urn:ckp:board/created_by')
            ELSE '{}'::jsonb END
  );

  RETURN NEW;
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

  RETURN v_verb;
END;
$function$;
