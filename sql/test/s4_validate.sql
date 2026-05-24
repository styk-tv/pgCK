\set ON_ERROR_STOP 1
DO $$
BEGIN
  IF ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
    <urn:ckp:prf:bad> a ckp:Proof ; ckp:about <urn:ckp:i:1> .', 1) THEN
    RAISE EXCEPTION 'expected malformed proof payload to be rejected';
  END IF;

  IF NOT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:ok> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "hmac+sha256" ;
    ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
    ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) THEN
    RAISE EXCEPTION 'expected v0.1.2 HMAC proof payload to be accepted';
  END IF;

  IF ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:old> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "ed25519+sha256" ;
    ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
    ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) THEN
    RAISE EXCEPTION 'expected old ed25519 proof payload to be rejected';
  END IF;

  IF position('random()' in pg_get_functiondef('ckp.validate(text,integer)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'expected ckp.validate to stop using random scratch graph ids';
  END IF;

  IF position('pg_backend_pid' in pg_get_functiondef('ckp.validate(text,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'expected ckp.validate to use a backend-local scratch graph id';
  END IF;
END;
$$;
