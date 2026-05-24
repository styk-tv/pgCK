\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
DO $$
DECLARE
  v_digest TEXT;
  v_body_sha TEXT;
  v_sig TEXT;
  v_method TEXT;
  v_expected_sig TEXT;
BEGIN
  v_digest := ckp.seal(
    'i-greet-1',
    '{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Ada"}'::jsonb
  );

  IF length(v_digest) <> 64 THEN
    RAISE EXCEPTION 'expected ckp.seal() to return a 64-char digest, got %', v_digest;
  END IF;

  IF (SELECT count(*) FROM ckp.instances WHERE id='i-greet-1') <> 1 THEN
    RAISE EXCEPTION 'expected one durable instance row';
  END IF;

  IF (SELECT count(*) FROM ckp.ledger WHERE instance_id='i-greet-1') <> 1 THEN
    RAISE EXCEPTION 'expected one durable ledger row';
  END IF;

  IF (SELECT count(*) FROM ckp.proof WHERE about='i-greet-1') <> 1 THEN
    RAISE EXCEPTION 'expected one durable proof row';
  END IF;

  SELECT body_sha256, sig
  INTO v_body_sha, v_sig
  FROM ckp.ledger
  WHERE instance_id='i-greet-1'
  ORDER BY seq DESC
  LIMIT 1;

  SELECT method
  INTO v_method
  FROM ckp.proof
  WHERE about='i-greet-1'
  ORDER BY id DESC
  LIMIT 1;

  v_expected_sig := encode(hmac(v_digest, (SELECT v FROM ckp.config WHERE k='identity_key'), 'sha256'), 'hex');

  IF v_body_sha IS DISTINCT FROM v_digest THEN
    RAISE EXCEPTION 'expected ledger digest to match returned digest';
  END IF;

  IF v_sig IS DISTINCT FROM v_expected_sig THEN
    RAISE EXCEPTION 'expected ledger signature to match HMAC digest signature';
  END IF;

  IF v_method IS DISTINCT FROM 'hmac+sha256' THEN
    RAISE EXCEPTION 'expected proof method to advertise HMAC semantics, got %', v_method;
  END IF;
END;
$$;
