\set ON_ERROR_STOP 1
DO $$
BEGIN
  IF ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    <urn:ckp:prf:bad> a ckp:Proof ; ckp:about <urn:ckp:i:1> .', 1) THEN
    RAISE EXCEPTION 'expected malformed proof payload to be rejected';
  END IF;

  IF NOT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:ok> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "hmac+sha256" ;
    ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
    ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) THEN
    RAISE EXCEPTION 'expected v0.1.2 HMAC proof payload to be accepted';
  END IF;

  -- v3.11 NOTE (#49): the v3.8 shape pinned ckp:method, so this ed25519
  -- payload was a REFUSED negative control. The v3.11 root's ProofShape
  -- requires method as xsd:string with no sh:in pin — the root rules, so a
  -- well-formed proof with any method string now VALIDATES. Live proofs are
  -- substrate-minted by _seal with its own method; the pin was validator
  -- policy, not the live gate. Whether the root should re-pin method is an
  -- upstream (CK-org) question, tracked on #49 — do not re-tighten here.
  IF NOT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:old> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "ed25519+sha256" ;
    ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
    ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) THEN
    RAISE EXCEPTION 'expected well-formed proof (any method string) to validate under the v3.11 root';
  END IF;

  IF position('random()' in pg_get_functiondef('ckp.validate(text,integer)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'expected ckp.validate to stop using random scratch graph ids';
  END IF;

  IF position('pg_backend_pid' in pg_get_functiondef('ckp.validate(text,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'expected ckp.validate to use a backend-local scratch graph id';
  END IF;
END;
$$;
