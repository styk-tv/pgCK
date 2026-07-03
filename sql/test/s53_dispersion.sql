-- s53_dispersion.sql — generic net + volume derived_dispersion (v0.4.17, T5).
--
-- GENERIC: split values about one concept (+1,+1,-0.8,-0.8) → net 0.4, volume 3.6. The
-- substrate returns net + volume only; κ = 1 − |net|/volume is the CONSUMER's calc (proving
-- the substrate carries no consumer math). Layering: grep for assent|polarity|kappa — zero.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
DO $$ BEGIN
  PERFORM ckp.seal('v-1','{"type":"urn:t:Item","urn:t:topic":"urn:t:split","urn:t:value":1.0}'::jsonb);
  PERFORM ckp.seal('v-2','{"type":"urn:t:Item","urn:t:topic":"urn:t:split","urn:t:value":1.0}'::jsonb);
  PERFORM ckp.seal('v-3','{"type":"urn:t:Item","urn:t:topic":"urn:t:split","urn:t:value":-0.8}'::jsonb);
  PERFORM ckp.seal('v-4','{"type":"urn:t:Item","urn:t:topic":"urn:t:split","urn:t:value":-0.8}'::jsonb);
END $$;
DO $$
DECLARE res jsonb; net numeric; vol numeric; kap numeric;
BEGIN
  res := ckp.derived_dispersion('urn:t:split','{"type":"urn:t:Item","about_prop":"urn:t:topic","about":"urn:t:split"}'::jsonb,'(i.body->>''urn:t:value'')::numeric',1);
  net := (res->>'net')::numeric; vol := (res->>'volume')::numeric; kap := 1 - abs(net)/vol;  -- κ is the CONSUMER's calc
  IF round(vol,4) <> 3.6 THEN RAISE EXCEPTION 's53 FAIL: volume expected 3.6, got %', vol; END IF;
  IF kap < 0.8 THEN RAISE EXCEPTION 's53 FAIL: split support should give high κ, got %', kap; END IF;
  RAISE NOTICE 's53 PASS: derived_dispersion net=% volume=% (consumer κ=%)', net, vol, round(kap,3);
END $$;
