-- s52_epsilon_materialize.sql — generic ε-materialize substrate (v0.4.16, T1-T4 + T6-T7).
--
-- GENERIC on purpose: items of type urn:t:Item carry urn:t:topic (the concept) and
-- urn:t:value (a stored numeric); the sealed formula under test is the plain SQL expression
-- (i.body->>'urn:t:value')::numeric. NO consumer type or math anywhere — the substrate
-- evaluates an opaque formula; it never learns what the value means. (Layering: grep this
-- file for assent|polarity|w_*|theta|lambda|kappa — must be zero.)
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- T1 — generic source watermark: MAX(ckp.ledger.seq) over the scope advances on a new seal.
DO $$ BEGIN
  PERFORM ckp.seal('item-1','{"type":"urn:t:Item","urn:t:topic":"urn:t:t1","urn:t:value":1.0}'::jsonb);
  PERFORM ckp.seal('item-2','{"type":"urn:t:Item","urn:t:topic":"urn:t:t1","urn:t:value":-0.8}'::jsonb);
END $$;
DO $$
DECLARE scope jsonb := '{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb; w1 bigint; w2 bigint;
BEGIN
  w1 := ckp._source_watermark(scope);
  IF COALESCE(w1,0)=0 THEN RAISE EXCEPTION 's52 FAIL: watermark should be >0, got %', w1; END IF;
  PERFORM ckp.seal('item-3','{"type":"urn:t:Item","urn:t:topic":"urn:t:t1","urn:t:value":1.0}'::jsonb);
  w2 := ckp._source_watermark(scope);
  IF w2 <= w1 THEN RAISE EXCEPTION 's52 FAIL: watermark must advance on a new seal (% -> %)', w1, w2; END IF;
  RAISE NOTICE 's52 PASS: generic source watermark advances (% -> %)', w1, w2;
END $$;

-- T2 — generic host-side materialize: evaluate the SEALED formula per in-scope item,
-- storing signed :contrib + absolute :contrib_abs. The formula is a plain SQL expression over
-- the item row alias i — NO consumer semantics; the substrate substitutes it, never contains it.
DO $$
DECLARE scope jsonb := '{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb; g text; net numeric;
BEGIN
  g := ckp._epsilon_materialize('urn:t:t1', scope, '(i.body->>''urn:t:value'')::numeric', 1);
  net := (pgrdf.sparql('PREFIX m:<urn:ckp:mat/> SELECT (SUM(?c) AS ?v) WHERE { GRAPH <'||g||'> { ?s m:contrib ?c } }')->>'v')::numeric;
  IF round(net,4) <> 1.2 THEN RAISE EXCEPTION 's52 FAIL: net expected 1.2 (1.0-0.8+1.0), got %', net; END IF;
  RAISE NOTICE 's52 PASS: generic materialize evaluates a sealed formula → net %', net;
END $$;

-- T3 — three-clause freshness + atomic committed-complete pointer. A just-published pointer at
-- the current watermark is fresh; a new seal within the same ε advances the watermark and makes
-- it stale (the watermark clause — the newest, most decisive fact must not read a stale phenotype).
DO $$
DECLARE scope jsonb := '{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb; wm bigint; fresh boolean;
BEGIN
  wm := ckp._source_watermark(scope);
  PERFORM ckp._phenotype_publish('urn:t:t1','urn:ckp:phenotype/urn-t-t1/1/'||wm,1,wm,now()+interval '1 hour');
  IF NOT ckp._phenotype_fresh('urn:t:t1',1,wm) THEN RAISE EXCEPTION 's52 FAIL: just-published must be fresh'; END IF;
  PERFORM ckp.seal('item-4','{"type":"urn:t:Item","urn:t:topic":"urn:t:t1","urn:t:value":1.0}'::jsonb);
  wm := ckp._source_watermark(scope);
  IF ckp._phenotype_fresh('urn:t:t1',1,wm) THEN RAISE EXCEPTION 's52 FAIL: new in-ε evidence must be STALE (watermark clause)'; END IF;
  RAISE NOTICE 's52 PASS: freshness detects within-ε new evidence';
END $$;

-- T4 — ckp.derived_sum: the generic net read ((e1) synchronous, fresh-only). Stale (item-4 was
-- sealed in T3) → re-materialize at the current watermark → atomic publish → SUM(:contrib).
-- items 1..4: 1.0-0.8+1.0+1.0 = 2.2. No bands/thresholds — the consumer applies those.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.derived_sum('urn:t:t1','{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb,'(i.body->>''urn:t:value'')::numeric',1);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's52 FAIL: derived_sum not ok: %', res; END IF;
  IF round((res->>'value')::numeric,4) <> 2.2 THEN RAISE EXCEPTION 's52 FAIL: value expected 2.2, got %', res->>'value'; END IF;
  RAISE NOTICE 's52 PASS: derived_sum (generic net) = %', res->>'value';
END $$;

-- T6 — over-budget enqueue returns recompute_in_progress + a durable job carrying scope+formula
-- (the bgworker completes it; the drain itself is exercised by the running worker, not asserted here).
DO $$
DECLARE res jsonb; n int;
BEGIN
  res := ckp.enqueue_materialize('urn:t:t1','{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb,'(i.body->>''urn:t:value'')::numeric',1);
  IF (res->>'recompute_in_progress')::boolean IS NOT TRUE THEN RAISE EXCEPTION 's52 FAIL: enqueue must return recompute_in_progress'; END IF;
  SELECT count(*) INTO n FROM ckp.materialize_job WHERE concept='urn:t:t1';
  IF n<>1 THEN RAISE EXCEPTION 's52 FAIL: durable job not enqueued (%).', n; END IF;
  RAISE NOTICE 's52 PASS: over-budget enqueue → recompute_in_progress + durable job (scope+formula)';
END $$;

-- T7 — within-ε recompute: a new seal advances the watermark, so the NEXT derived_sum re-materializes
-- and the value moves by the new evidence (closes the "stale on the newest, most decisive fact" hole).
DO $$
DECLARE scope jsonb := '{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:t1"}'::jsonb;
        f text := '(i.body->>''urn:t:value'')::numeric'; a numeric; b numeric;
BEGIN
  a := (ckp.derived_sum('urn:t:t1',scope,f,1)->>'value')::numeric;
  PERFORM ckp.seal('item-9','{"type":"urn:t:Item","urn:t:topic":"urn:t:t1","urn:t:value":1.0}'::jsonb);
  b := (ckp.derived_sum('urn:t:t1',scope,f,1)->>'value')::numeric;
  IF round(b-a,4) <> 1.0 THEN RAISE EXCEPTION 's52 FAIL: within-ε new evidence did not move the value (% -> %)', a, b; END IF;
  RAISE NOTICE 's52 PASS: within-ε new evidence moves the derived value (% -> %)', a, b;
END $$;

-- T7 — non-intrusiveness: an unrelated dispatch (instance.get) NEVER touches the materialize path
-- (the phenotype pointer's built_at is unchanged). "Won't hinder regular operations" is a guarantee.
DO $$
DECLARE t0 timestamptz; t1 timestamptz;
BEGIN
  SELECT built_at INTO t0 FROM ckp.phenotype_ptr WHERE concept='urn:t:t1';
  PERFORM ckp.dispatch('instance.get','{"id":"item-1"}'::jsonb);
  SELECT built_at INTO t1 FROM ckp.phenotype_ptr WHERE concept='urn:t:t1';
  IF t0 IS DISTINCT FROM t1 THEN RAISE EXCEPTION 's52 FAIL: unrelated dispatch rebuilt the phenotype'; END IF;
  RAISE NOTICE 's52 PASS: unrelated dispatch never on the materialize path';
END $$;
