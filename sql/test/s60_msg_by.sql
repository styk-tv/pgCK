-- s60_msg_by.sql — F4: every delivered governed event carries `by` = the server-attributed sender.
--
-- The `by` header on a delivered event is the sealed `created_by` — which derives from the VERIFIED
-- `ckp.requester` (F-A), never a client field. Peers (other kernels, web bots, users) see who-said-what
-- without the client asserting it, and a forged payload identity can never set `by`. (CK.Lib.Js#9 msg.by.)
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
-- The trusted ingress sets the verified requester (as the auth-callout will); a client cannot.
SELECT set_config('ckp.requester','alice', false);

DO $$
DECLARE res jsonb; v_id text; v_by text;
BEGIN
  res := ckp.dispatch('task.create','{"task":{"target_kernel":"Build","title":"ship"},"sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's60 FAIL: task.create not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT o.headers->>'by' INTO v_by
    FROM ckp.outbox o JOIN ckp.ledger l ON l.seq = o.ledger_seq
    WHERE l.instance_id = v_id ORDER BY o.seq DESC LIMIT 1;
  IF v_by = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's60 FAIL (SECURITY): delivered event `by` = forged payload sub (%)', v_by;
  END IF;
  IF v_by IS DISTINCT FROM 'urn:ckp:participant:alice' THEN
    RAISE EXCEPTION 's60 FAIL: delivered event must carry `by` = the verified sender urn:ckp:participant:alice, got % (headers=%)',
      v_by, (SELECT o.headers FROM ckp.outbox o JOIN ckp.ledger l ON l.seq=o.ledger_seq WHERE l.instance_id=v_id ORDER BY o.seq DESC LIMIT 1);
  END IF;
  RAISE NOTICE 's60 PASS: delivered governed event carries `by` = the verified sender (%); forged payload sub ignored', v_by;
END $$;
