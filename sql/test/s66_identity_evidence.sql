-- s66_identity_evidence.sql — THE IDENTITY CONTRACT'S SEALED HALF (0.4.70).
--
-- The fleet contract (pgRDF operation-1786906298085342000 ⇄ pgck
-- operation-1786897156122855000): two relay-set GUCs on the channel clients
-- cannot write land as proof rows, so verified-at-time is sealable evidence.
--
--   (1) both GUCs set → the fact carries THREE proofs: hmac (bytes),
--       token-residue (digest = the claims fingerprint itself), and
--       grant-ref:<urn> (the acting Grant, readable for resolve-never-believe);
--   (2) NEVER THE TOKEN, structurally: a JWT-shaped value in ckp.token_residue
--       REFUSES the seal — a raw credential in the evidence plane is permanent;
--   (3) absent GUCs → exactly ONE proof — no rows, honestly unattested;
--   (4) the door's reader exposes all rows and verify() stays true (the plural
--       readers of 0.4.66, exercised on the new methods).
--
-- Run (booted by the smoke): psql … < s66_identity_evidence.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's66-test';

-- fixture type through governance (declared, judged — never invented).
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_class', 'about','urn:ckp:s66-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('class','urn:ckp:s66-test/type/Note',
      'properties', jsonb_build_array(jsonb_build_object('path','urn:ckp:s66-test/prop/text','minCount',1)))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's66 FAIL (0): propose: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's66 FAIL (0): vote: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's66 FAIL (0): apply: %', ap; END IF;
END $$;

-- (1) both GUCs present → three proofs, each with its declared semantics.
DO $$
DECLARE v_sha text; n int; v_res text := repeat('ab', 32);
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s66-relay-user', true);
  PERFORM set_config('ckp.token_residue', v_res, true);
  PERFORM set_config('ckp.grant_ref', 'urn:ckp:s66-test/grant/write-notes', true);
  v_sha := ckp.seal('s66-note-attested', jsonb_build_object(
    'type','urn:ckp:s66-test/type/Note', '@id','urn:s66:note-attested',
    'urn:ckp:s66-test/prop/text','sealed under the identity contract'));
  SELECT count(*) INTO n FROM ckp.proof WHERE about = 's66-note-attested';
  IF n <> 3 THEN RAISE EXCEPTION 's66 FAIL (1): expected 3 proofs (bytes + residue + grant), got %', n; END IF;
  PERFORM 1 FROM ckp.proof WHERE about='s66-note-attested' AND method='token-residue' AND digest = v_res;
  IF NOT FOUND THEN RAISE EXCEPTION 's66 FAIL (1): token-residue row missing or not carrying the fingerprint'; END IF;
  PERFORM 1 FROM ckp.proof WHERE about='s66-note-attested'
    AND method = 'grant-ref:urn:ckp:s66-test/grant/write-notes' AND digest = v_sha;
  IF NOT FOUND THEN RAISE EXCEPTION 's66 FAIL (1): grant-ref row missing, or its URN not readable from method'; END IF;
END $$;

-- (2) NEVER THE TOKEN: a JWT-shaped residue refuses the seal, naming the rule.
DO $$
DECLARE v_sha text;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s66-relay-user', true);
  PERFORM set_config('ckp.token_residue', 'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzNjYifQ.sig', true);
  BEGIN
    v_sha := ckp.seal('s66-note-tokenleak', jsonb_build_object(
      'type','urn:ckp:s66-test/type/Note', '@id','urn:s66:note-tokenleak',
      'urn:ckp:s66-test/prop/text','this must refuse'));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ 'NEVER the token' THEN
      RAISE EXCEPTION 's66 FAIL (2): refused for the wrong reason: %', SQLERRM; END IF;
    RETURN;  -- refused as designed
  END;
  RAISE EXCEPTION 's66 FAIL (2): a raw JWT sealed into the evidence plane (sha %)', v_sha;
END $$;

-- engine hygiene after the deliberate abort (see s38/s64's notes).
DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (3) absent GUCs → exactly one proof; absence is the honest record.
DO $$
DECLARE v_sha text; n int;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s66-naked-but-named', true);
  PERFORM set_config('ckp.token_residue', '', true);
  PERFORM set_config('ckp.grant_ref', '', true);
  v_sha := ckp.seal('s66-note-plain', jsonb_build_object(
    'type','urn:ckp:s66-test/type/Note', '@id','urn:s66:note-plain',
    'urn:ckp:s66-test/prop/text','sealed with no identity evidence attached'));
  SELECT count(*) INTO n FROM ckp.proof WHERE about = 's66-note-plain';
  IF n <> 1 THEN RAISE EXCEPTION 's66 FAIL (3): expected exactly 1 proof, got % — absence must stay absent', n; END IF;
END $$;

-- (4) the door's readers: verify() true, all rows exposed.
DO $$
DECLARE prov jsonb;
BEGIN
  IF NOT ckp.verify('s66-note-attested') THEN
    RAISE EXCEPTION 's66 FAIL (4): verify() false on a three-proof fact'; END IF;
  prov := ckp.dispatch('provenance', jsonb_build_object('id','s66-note-attested'));
  IF jsonb_array_length(prov->'proofs') <> 3 THEN
    RAISE EXCEPTION 's66 FAIL (4): the door exposes % proof rows, expected 3', jsonb_array_length(prov->'proofs'); END IF;
END $$;

\echo s66_identity_evidence: PASS
