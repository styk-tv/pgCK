-- CKF-3: ckp.seal() participant identity mapping — MIGRATED at 0.4.64.
-- The original acceptance pinned two behaviours the substrate has since
-- outlawed: a payload {sub} honoured as identity (the E1 claim path — identity
-- is SERVER-derived, a claim is ignored when a verified requester exists), and
-- an anon:<nonce> minted when nobody was present (unattributed writes now
-- REFUSE; ck-dev's finding-1786732252462817000). The golden now pins the
-- doctrine: requester wins, claims decorate at most, absence refuses.
--
-- Canonical IRI key is the v3.11 core predicate
-- https://conceptkernel.org/ontology/v3.11/core#participant; display claims
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

-- (a) the REQUESTER is alice: canonical IRI urn:ckp:participant:alice is
-- persisted from the VERIFIED identity — the payload claims agree here and add
-- only display fields. Identity comes from the session, never the payload.
SELECT set_config('ckp.requester','alice',false);
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

  IF (v_stored->>'https://conceptkernel.org/ontology/v3.11/core#participant')
       <> 'urn:ckp:participant:alice' THEN
    RAISE EXCEPTION 's9 FAIL: alice participant IRI not persisted, got %',
      v_stored->>'https://conceptkernel.org/ontology/v3.11/core#participant';
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

-- (b) WITHOUT any identity: the seal REFUSES (0.4.64). The anon mint is gone —
-- a fact belonging to nobody is permanent, and per-call fresh uuids let one
-- caller impersonate many distinct parties. The refusal must name the clause.
DO $$
DECLARE
  v_body jsonb := '{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Bob"}'::jsonb;
BEGIN
  PERFORM set_config('ckp.requester','',true);   -- txn-local: clear the suite identity
  BEGIN
    PERFORM ckp.seal('cf3-anon', v_body);
    RAISE EXCEPTION 's9 FAIL: unattributed seal was ACCEPTED — the refusal is not enforced';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%unattributed write refused%' THEN RAISE; END IF;
    RAISE NOTICE 's9 PASS: unattributed seal refused with the clause named';
  END;
  IF EXISTS (SELECT 1 FROM ckp.instances WHERE id = 'cf3-anon') THEN
    RAISE EXCEPTION 's9 FAIL: refused seal left a row behind';
  END IF;
END $$;

-- (c) MIGRATED (0.4.64): an empty payload sub used to fall back to a minted
-- anon. Now: the empty CLAIM is simply ignored and the verified REQUESTER
-- wins — which is the doctrine (claims never beat the session identity), and
-- with no requester either, (b) already proved it refuses.
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
  SELECT body->>'https://conceptkernel.org/ontology/v3.11/core#participant'
    INTO v_iri FROM ckp.instances WHERE id = 'cf3-empty-sub';
  IF v_iri <> 'urn:ckp:participant:alice' THEN
    RAISE EXCEPTION 's9 FAIL: empty claim must lose to the verified requester, got %', v_iri;
  END IF;
END $$;

-- (d) the normaliser, exercised through the REQUESTER (0.4.64: the payload
-- claim path is dead while a requester exists, so the normaliser is fed by the
-- session identity — the same path the relay uses).
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'urn:ckp:kernel#Greeting',
    'urn:ckp:kernel#name', 'Dia'
  );
  v_iri text;
BEGIN
  PERFORM set_config('ckp.requester', 'Alice Smith ', true);
  PERFORM ckp.seal('cf3-norm', v_body);
  SELECT body->>'https://conceptkernel.org/ontology/v3.11/core#participant'
    INTO v_iri FROM ckp.instances WHERE id = 'cf3-norm';
  IF v_iri <> 'urn:ckp:participant:alice-smith' THEN
    RAISE EXCEPTION 's9 FAIL: sub normalisation wrong, expected urn:ckp:participant:alice-smith got %', v_iri;
  END IF;
END $$;

\echo s9_seal_participant: PASS
