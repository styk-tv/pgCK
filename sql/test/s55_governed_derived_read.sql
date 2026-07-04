-- s55_governed_derived_read.sql — scoring-loop layer 3 (pgCK#1 read exposure).
--
-- The role-floor-reachable governed DERIVED-read dispatch verb: a consumer seals a {formula,
-- scope} affordance; dispatch routes it (plane='derived') to run_derived_affordance; a
-- ck_participant client gets the BAND-LESS envelope {ok, value, scored, freshness}. Generic —
-- the verb name + formula are the consumer's sealed fact; grep this + the substrate for
-- assent|band|polarity|kappa — must be zero in pgCK code.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- signals about one concept (generic items)
DO $$ BEGIN
  PERFORM ckp.seal('sig-a','{"type":"urn:t:Item","urn:t:topic":"urn:t:c1","urn:t:value":1.0}'::jsonb);
  PERFORM ckp.seal('sig-b','{"type":"urn:t:Item","urn:t:topic":"urn:t:c1","urn:t:value":0.5}'::jsonb);
END $$;

-- seal a derived affordance (the governance apply step calls this from a sealed proposal)
DO $$ BEGIN
  PERFORM ckp.register_derived_affordance(
    jsonb_build_object('proposalDetail', jsonb_build_object(
      'verb', 'demo.score',
      'formula', '(i.body->>''urn:t:value'')::numeric',
      'scope', jsonb_build_object('type','urn:t:Item','about_prop','urn:t:topic'))),
    'demo', 1);
END $$;

-- the CLIENT path: ck_participant dispatches the verb, binds only the concept, gets the envelope.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('demo.score', '{"concept":"urn:t:c1"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's55 FAIL: dispatch not ok: %', res; END IF;
  IF round((res->>'value')::numeric,4) <> 1.5 THEN RAISE EXCEPTION 's55 FAIL: value expected 1.5, got % (%)', res->>'value', res; END IF;
  IF (res->>'scored') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's55 FAIL: scored discriminator missing: %', res; END IF;
  IF (res->'freshness') IS NULL THEN RAISE EXCEPTION 's55 FAIL: freshness field required: %', res; END IF;
  IF res ? 'band' THEN RAISE EXCEPTION 's55 FAIL: substrate must stay band-less, got band: %', res; END IF;
  RAISE NOTICE 's55 PASS: governed derived read via dispatch under the role floor (value=%, scored=%, fresh=%)',
    res->>'value', res->>'scored', res->'freshness'->>'fresh';
END $$;

-- missing concept param → typed error, never a bare value
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('demo.score', '{}'::jsonb);
  IF (res->>'error') IS DISTINCT FROM 'missing_param' THEN RAISE EXCEPTION 's55 FAIL: missing concept must be missing_param, got %', res; END IF;
  RAISE NOTICE 's55 PASS: missing concept param → typed error (%)', res->>'error';
END $$;
