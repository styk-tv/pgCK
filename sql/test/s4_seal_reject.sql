\set ON_ERROR_STOP 1
-- 0.4.64: unattributed seals REFUSE (the anon mint is gone). A test names
-- its service identity explicitly — the sanctioned operator form.
SELECT set_config('ckp.requester','svc:smoke-suite',false);

SELECT set_config('ckp.project','demo',false);
DO $$ BEGIN
  PERFORM ckp.seal('i-bad-1','{"type":"urn:ckp:kernel#Greeting"}'::jsonb);
  RAISE EXCEPTION 'TEST FAILED: should reject missing name';
EXCEPTION WHEN others THEN
  -- v3.11 (#49): the gate refuses via the composed shape report (MinCount on
  -- kernel#name), not the v3.9-era 'missing required' prose. Match the gate.
  IF SQLERRM LIKE '%fails the composed shape gate%' THEN RAISE NOTICE 'PASS: %', SQLERRM;
  ELSE RAISE; END IF; END $$;
SELECT count(*)=0 AS no_bad FROM ckp.instances WHERE id='i-bad-1';
