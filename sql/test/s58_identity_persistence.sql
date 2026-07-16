-- s58_identity_persistence.sql — server-derived identity on the seal path (F-A / pgCK#9,#10).
--
-- The dispatch identity that becomes a sealed instance's created_by MUST derive from the
-- VERIFIED CONNECTION — the trusted `ckp.requester` GUC that the ingress relay sets from the
-- NATS-verified bearer — NEVER from a client-supplied payload field. A forged payload {sub}
-- must be IGNORED. This is the regression proving instances are attributable and un-forgeable,
-- the floor the multi-user session protocol (SPEC.CKP.SESSION.v3.9.2) stands on.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- The trusted ingress (relay) sets the verified requester once, from the verified bearer.
-- A participant client cannot set this GUC (it is set inside the trusted relay, not from payload).
SELECT set_config('ckp.requester','test26', false);

-- (1) task.create — a FORGED payload {sub:'attacker'} must be ignored; created_by = verified requester.
DO $$
DECLARE res jsonb; v_id text; cby text;
BEGIN
  res := ckp.dispatch('task.create',
    '{"task":{"target_kernel":"Build","title":"ship it"},"sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's58 FAIL: task.create not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'https://conceptkernel.org/ontology/v3.7/created_by' INTO cby FROM ckp.instances WHERE id = v_id;
  IF cby = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's58 FAIL (SECURITY): forged payload sub became created_by (%) — identity MUST derive from the verified connection', cby;
  END IF;
  IF cby IS DISTINCT FROM 'urn:ckp:participant:test26' THEN
    RAISE EXCEPTION 's58 FAIL: task.create created_by must be the verified requester urn:ckp:participant:test26, got % (body=%)',
      cby, (SELECT body FROM ckp.instances WHERE id=v_id);
  END IF;
  RAISE NOTICE 's58 PASS: task.create created_by derives from the verified requester; forged payload sub ignored (%)', cby;
END $$;

-- (2) notify (message path — the msg.by / created_by attribution) — same rule.
DO $$
DECLARE res jsonb; v_id text; cby text;
BEGIN
  res := ckp.dispatch('notify',
    '{"from":"a","to":"b","body":"hi","sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's58 FAIL: notify not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'https://conceptkernel.org/ontology/v3.7/created_by' INTO cby FROM ckp.instances WHERE id = v_id;
  IF cby = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's58 FAIL (SECURITY): forged payload sub became message created_by (%)', cby;
  END IF;
  IF cby IS DISTINCT FROM 'urn:ckp:participant:test26' THEN
    RAISE EXCEPTION 's58 FAIL: notify created_by must be the verified requester, got %', cby;
  END IF;
  RAISE NOTICE 's58 PASS: notify created_by derives from the verified requester; forged payload sub ignored (%)', cby;
END $$;
