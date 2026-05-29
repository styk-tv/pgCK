-- CKF-3: ckp.seal() participant identity mapping.
-- Acceptance (per SPEC.pgCK.ROADMAP.v0.2-devel §9, line 179):
--   seal with participant {sub:"alice"} → instance body carries
--   urn:ckp:participant:alice; seal without participant → an anonymous URN
--   urn:ckp:participant:anon:<nonce> is minted into the body.
--
-- Canonical IRI key is the v3.8 core predicate
-- https://conceptkernel.org/ontology/v3.8/core#participant; display claims
-- (preferred_username, email) ride as non-authoritative participant_display_name
-- / participant_email per NOTIFIES.pgCK §D.
--
-- Uses the non-Task/Goal type urn:ckp:kernel#Greeting (like s4) so the SHACL
-- gate (ckp.project_links) never fires — participant injection is gate-safe and
-- needs no task.ttl/goal.ttl board setup.
--
-- Run: psql -U pgck -d pgck -v ON_ERROR_STOP=1 < sql/test/s9_seal_participant.sql

\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

-- (a) WITH participant {sub:"alice", ...}: canonical IRI urn:ckp:participant:alice
-- is persisted, the raw claims object is replaced, and display fields ride along.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'urn:ckp:kernel#Greeting',
    'urn:ckp:kernel#name', 'Ada',
    'participant', jsonb_build_object(
      'sub', 'alice',
      'preferred_username', 'Alice A.',
      'email', 'alice@example.org')
  );
  v_stored jsonb;
BEGIN
  PERFORM ckp.seal('cf3-alice', v_body);

  SELECT body INTO v_stored FROM ckp.instances WHERE id = 'cf3-alice';

  IF (v_stored->>'https://conceptkernel.org/ontology/v3.8/core#participant')
       <> 'urn:ckp:participant:alice' THEN
    RAISE EXCEPTION 's9 FAIL: alice participant IRI not persisted, got %',
      v_stored->>'https://conceptkernel.org/ontology/v3.8/core#participant';
  END IF;

  -- Raw claims object must be replaced (not left alongside the IRI).
  IF v_stored ? 'participant' THEN
    RAISE EXCEPTION 's9 FAIL: raw participant claims object left in body';
  END IF;

  -- Display claims carried as non-authoritative attributes.
  IF (v_stored->>'participant_display_name') IS DISTINCT FROM 'Alice A.' THEN
    RAISE EXCEPTION 's9 FAIL: participant_display_name not carried, got %',
      v_stored->>'participant_display_name';
  END IF;
  IF (v_stored->>'participant_email') IS DISTINCT FROM 'alice@example.org' THEN
    RAISE EXCEPTION 's9 FAIL: participant_email not carried, got %',
      v_stored->>'participant_email';
  END IF;

  -- The body was rewritten before the SHA, so verify() must stay consistent.
  IF NOT ckp.verify('cf3-alice') THEN
    RAISE EXCEPTION 's9 FAIL: verify() failed for participant-bearing instance';
  END IF;
END $$;

-- (b) WITHOUT participant: an anonymous URN urn:ckp:participant:anon:<nonce>
-- is minted into the body.
DO $$
DECLARE
  v_body jsonb := '{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Bob"}'::jsonb;
  v_stored jsonb;
  v_iri text;
BEGIN
  PERFORM ckp.seal('cf3-anon', v_body);

  SELECT body INTO v_stored FROM ckp.instances WHERE id = 'cf3-anon';
  v_iri := v_stored->>'https://conceptkernel.org/ontology/v3.8/core#participant';

  IF v_iri NOT LIKE 'urn:ckp:participant:anon:%' THEN
    RAISE EXCEPTION 's9 FAIL: anon URN not minted, got %', v_iri;
  END IF;

  -- A nonce must follow the anon: prefix.
  IF length(v_iri) <= length('urn:ckp:participant:anon:') THEN
    RAISE EXCEPTION 's9 FAIL: anon URN has no nonce, got %', v_iri;
  END IF;

  -- No display fields when anonymous.
  IF v_stored ? 'participant_display_name' OR v_stored ? 'participant_email' THEN
    RAISE EXCEPTION 's9 FAIL: anon instance carries display fields';
  END IF;

  IF NOT ckp.verify('cf3-anon') THEN
    RAISE EXCEPTION 's9 FAIL: verify() failed for anon instance';
  END IF;
END $$;

-- (c) participant present but sub empty → treated as anonymous.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'urn:ckp:kernel#Greeting',
    'urn:ckp:kernel#name', 'Cleo',
    'participant', jsonb_build_object('sub', '   ')
  );
  v_iri text;
BEGIN
  PERFORM ckp.seal('cf3-empty-sub', v_body);
  SELECT body->>'https://conceptkernel.org/ontology/v3.8/core#participant'
    INTO v_iri FROM ckp.instances WHERE id = 'cf3-empty-sub';
  IF v_iri NOT LIKE 'urn:ckp:participant:anon:%' THEN
    RAISE EXCEPTION 's9 FAIL: empty sub should fall back to anon, got %', v_iri;
  END IF;
END $$;

-- (d) non-trivial sub exercises the normaliser: mixed case + spaces + dot/@
-- 'Alice Smith ' → trim/lower → 'alice smith' → non-[a-z0-9-]+ → 'alice-smith'.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'urn:ckp:kernel#Greeting',
    'urn:ckp:kernel#name', 'Dia',
    'participant', jsonb_build_object('sub', 'Alice Smith ')
  );
  v_iri text;
BEGIN
  PERFORM ckp.seal('cf3-norm', v_body);
  SELECT body->>'https://conceptkernel.org/ontology/v3.8/core#participant'
    INTO v_iri FROM ckp.instances WHERE id = 'cf3-norm';
  IF v_iri <> 'urn:ckp:participant:alice-smith' THEN
    RAISE EXCEPTION 's9 FAIL: sub normalisation wrong, expected urn:ckp:participant:alice-smith got %', v_iri;
  END IF;
END $$;

\echo s9_seal_participant: PASS
