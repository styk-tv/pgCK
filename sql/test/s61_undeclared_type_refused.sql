-- s61 — P0-D mechanism 2 (pgCK#27): sealing under an UNDECLARED TYPE is refused.
--
-- The live defect: SHACL is target-driven, so a type no shape targets is
-- validated by nothing and seals verified:true with an arbitrary body. The
-- substrate type pre-check (ckp._type_admitted, a lookup not a shape) refuses
-- it before validation. This test FAILS if the pre-check is removed — sealing
-- the invented type would then succeed and the assertion below trips.
--
-- Run (booted + kernel loaded by the smoke harness): psql … < s61_...sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

-- (1) an INVENTED type URN — targeted by no shape, declared by no class — is REFUSED,
--     and leaves no row. This is the exact shape of the live defect.
DO $rej$
DECLARE caught text;
BEGIN
  BEGIN
    PERFORM ckp.seal('s61-invented',
      '{"type":"urn:ckp:demo/type/CompletelyInvented","urn:ckp:demo/prop/whatever":"silt"}'::jsonb);
    RAISE EXCEPTION 's61 FAIL: invented type sealed — the undeclared-type gate is not firing (P0-D regressed)';
  EXCEPTION WHEN others THEN caught := SQLERRM;
  END;
  IF caught NOT LIKE '%not admitted%' THEN
    RAISE EXCEPTION 's61 FAIL: invented type refused, but not by the admitted-type gate: %', caught;
  END IF;
END $rej$;
SELECT count(*)=0 AS s61_no_invented FROM ckp.instances WHERE id='s61-invented';

-- (1b) validate PREDICTS seal (#27): the same invented type reports conforms=false,
--      never the vacuous conforms=true. FAILS if validate skips the pre-check.
DO $vpred$
DECLARE res jsonb;
BEGIN
  res := ckp.validate_instance('{"body":{"type":"urn:ckp:demo/type/CompletelyInvented","x":1}}'::jsonb);
  IF (res->>'conforms') IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 's61 FAIL: validate must predict the seal refusal for an undeclared type (validate<=>seal), got %', res;
  END IF;
END $vpred$;

-- (2) a DECLARED type (Greeting — GreetingShape targets it in the demo kernel/ck)
--     still seals: the gate refuses the undeclared, never the declared.
DO $ok$
DECLARE d text;
BEGIN
  d := ckp.seal('s61-declared',
    '{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Ada"}'::jsonb);
  IF length(d) <> 64 THEN RAISE EXCEPTION 's61 FAIL: declared Greeting did not seal (digest %)', d; END IF;
END $ok$;
SELECT count(*)=1 AS s61_declared_ok FROM ckp.instances WHERE id='s61-declared';

\echo s61_undeclared_type_refused: PASS
