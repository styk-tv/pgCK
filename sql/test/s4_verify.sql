\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
DO $$
BEGIN
  PERFORM ckp.seal('i-v-clean','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Bo"}'::jsonb);
  IF NOT ckp.verify('i-v-clean') THEN
    RAISE EXCEPTION 'expected clean governed write to verify';
  END IF;

  PERFORM set_config('ckp.identity_key', '', false);
  IF NOT ckp.verify('i-v-clean') THEN
    RAISE EXCEPTION 'expected verification to keep working after the session identity key is cleared';
  END IF;

  PERFORM ckp.seal('i-v-proof','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Cy"}'::jsonb);
  UPDATE ckp.proof
  SET method='ed25519+sha256'
  WHERE about='i-v-proof';
  IF ckp.verify('i-v-proof') THEN
    RAISE EXCEPTION 'expected proof-method tampering to fail verification';
  END IF;

  PERFORM ckp.seal('i-v-ledger','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Di"}'::jsonb);
  UPDATE ckp.ledger
  SET sig='bad-signature'
  WHERE instance_id='i-v-ledger';
  IF ckp.verify('i-v-ledger') THEN
    RAISE EXCEPTION 'expected ledger-signature tampering to fail verification';
  END IF;

  PERFORM ckp.seal('i-v-body','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Eli"}'::jsonb);
  UPDATE ckp.instances
  SET body=body||'{"x":1}'::jsonb
  WHERE id='i-v-body';
  IF ckp.verify('i-v-body') THEN
    RAISE EXCEPTION 'expected body tampering to fail verification';
  END IF;
END;
$$;
