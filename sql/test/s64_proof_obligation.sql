-- s64_proof_obligation.sql — SEALED PROOF OBLIGATIONS (0.4.65, §5b).
--
-- The seal's exit is extensible by agreement: a governed op registers a
-- proof-producer that every future seal of the target type must satisfy, and
-- each satisfaction lands as a second ckp.proof row naming the agreement.
-- This is the joint ckp.proof's absent uniqueness was placed for.
--
--   (1) two NAMED parties agree (quorum 2) to bind the debut check —
--       digest-match — onto a declared type; apply registers the obligation;
--   (2) a candidate citing a FABRICATED surfaceDigest is REFUSED at seal
--       (the hole ck-lib-js measured: form-valid, reference-false);
--   (3) a candidate citing a digest an Epoch actually sealed passes and
--       carries TWO proofs: hmac+sha256 and obligation:<name>;
--   (4) citing a REAL digest under the WRONG epoch number is refused —
--       the pair must sit on one sealed Epoch;
--   (5) the agreement leaves by the same governed road it entered
--       (active:false), after which the fabricated citation seals again —
--       with exactly ONE proof row: no obligation, no mark.
--
-- Run (booted by the smoke): psql … < s64_proof_obligation.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's64-test';

-- (0) declare the citing type through governance: s64:Report cites a surface.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_class', 'about','urn:ckp:s64-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('class','urn:ckp:s64-test/type/Report',
      'properties', jsonb_build_array(jsonb_build_object(
        'path','https://conceptkernel.org/ontology/v3.11/core#surfaceDigest','minCount',1)))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (0): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (0): vote rejected: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (0): apply rejected: %', ap; END IF;
END $$;

-- (1) the AGREEMENT: quorum 2, two distinct named parties — an obligation is
--     never one party's reflex. Then apply registers it.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_proof_obligation', 'about','urn:ckp:s64-test/kernel/ck', 'requires_quorum',2,
    'detail', jsonb_build_object('obligation','cite-real-surface',
      'targetType','urn:ckp:s64-test/type/Report', 'check','digest-match')));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (1): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  PERFORM set_config('ckp.requester', 'svc:s64-party-one', true);
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (1): vote one rejected: %', vt; END IF;
  PERFORM set_config('ckp.requester', 'svc:s64-party-two', true);
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (1): vote two rejected: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (1): apply rejected: %', ap; END IF;
  IF (ap#>>'{applied,proof_obligation}') <> 'cite-real-surface' THEN
    RAISE EXCEPTION 's64 FAIL (1): obligation not registered at apply: %', ap; END IF;
END $$;

-- (2) THE HOLE, CLOSED: a fabricated sixty-four-hex digest is form-valid (the
--     shape gate passes it) and reference-false (no Epoch sealed it). Before
--     this release it sealed verified:true. Now the obligation refuses it.
DO $$
DECLARE v_sha text;
BEGIN
  BEGIN
    v_sha := ckp.seal('s64-report-bogus', jsonb_build_object(
      'type','urn:ckp:s64-test/type/Report', '@id','urn:s64:report-bogus',
      'https://conceptkernel.org/ontology/v3.11/core#surfaceDigest', repeat('f',64)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ 'proof obligation cite-real-surface' THEN
      RAISE EXCEPTION 's64 FAIL (2): refused for the wrong reason: %', SQLERRM; END IF;
    RETURN;  -- refused as expected
  END;
  RAISE EXCEPTION 's64 FAIL (2): fabricated digest sealed (sha %) — the obligation did not run', v_sha;
END $$;

-- engine hygiene: the aborted seal above interned the fabricated literal into
-- pgrdf's shmem term cache in a poisoned state — a later body reusing the SAME
-- literal (case 5) would store it and SHACL would not see it (MinCount, value
-- null). Known engine defect; the documented remedy is a reset after ANY
-- aborted seal. Guarded like bootstrap's.
DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (3) THE HONEST CITATION: name a digest an Epoch of THIS kernel actually
--     sealed — it passes, and the fact carries two proofs: the bytes (hmac)
--     and the agreement (obligation:cite-real-surface), same digest.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        v_dig text; v_ep text; v_sha text; n int;
BEGIN
  SELECT body->>(C||'surfaceDigest'), body->>(C||'epoch') INTO v_dig, v_ep
    FROM ckp.instances WHERE body->>'type' = C||'Epoch' AND id LIKE 'epoch-s64-test-%'
    ORDER BY ts_created DESC LIMIT 1;
  IF v_dig IS NULL THEN RAISE EXCEPTION 's64 FAIL (3): no sealed Epoch to cite'; END IF;
  v_sha := ckp.seal('s64-report-honest', jsonb_build_object(
    'type','urn:ckp:s64-test/type/Report', '@id','urn:s64:report-honest',
    C||'surfaceDigest', v_dig, C||'epoch', v_ep::numeric));
  SELECT count(*) INTO n FROM ckp.proof WHERE about = 's64-report-honest';
  IF n <> 2 THEN RAISE EXCEPTION 's64 FAIL (3): expected 2 proofs (bytes + agreement), got %', n; END IF;
  PERFORM 1 FROM ckp.proof WHERE about = 's64-report-honest'
    AND method = 'obligation:cite-real-surface' AND digest = v_sha;
  IF NOT FOUND THEN RAISE EXCEPTION 's64 FAIL (3): obligation proof row missing or digest-divergent'; END IF;
  -- 0.4.66 — THE READERS, negative-controlled by the mechanism's own debut:
  -- the first obligation-guarded fact on the bench verified FALSE seconds after
  -- sealing cleanly, because verify() took the LAST proof row and demanded it
  -- be hmac. Plural proofs are the feature; readers select the byte-proof by
  -- METHOD and expose the rest.
  IF NOT ckp.verify('s64-report-honest') THEN
    RAISE EXCEPTION 's64 FAIL (3): ckp.verify false on an obligation-guarded fact — a reader still assumes one proof per fact'; END IF;
  IF jsonb_array_length(ckp.dispatch('provenance', jsonb_build_object('id','s64-report-honest'))->'proofs') <> 2 THEN
    RAISE EXCEPTION 's64 FAIL (3): the door does not expose both proof rows — the obligation mark exists only for parties with table access'; END IF;
END $$;

-- (4) THE PAIR: a real digest under the WRONG epoch number is exactly the
--     dishonesty digest-match exists to refuse — both halves of the citation
--     must sit on ONE sealed Epoch.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        v_dig text; v_sha text;
BEGIN
  SELECT body->>(C||'surfaceDigest') INTO v_dig
    FROM ckp.instances WHERE body->>'type' = C||'Epoch' AND id LIKE 'epoch-s64-test-%'
    ORDER BY ts_created DESC LIMIT 1;
  BEGIN
    v_sha := ckp.seal('s64-report-mispair', jsonb_build_object(
      'type','urn:ckp:s64-test/type/Report', '@id','urn:s64:report-mispair',
      C||'surfaceDigest', v_dig, C||'epoch', 999999));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ 'proof obligation cite-real-surface' THEN
      RAISE EXCEPTION 's64 FAIL (4): refused for the wrong reason: %', SQLERRM; END IF;
    RETURN;  -- refused as expected
  END;
  RAISE EXCEPTION 's64 FAIL (4): mismatched (epoch,digest) pair sealed (sha %)', v_sha;
END $$;

-- same engine hygiene after the second deliberate abort (see case 2's note).
DO $$ BEGIN IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN PERFORM pgrdf.shmem_reset(); END IF; END $$;

-- (5) THE ROAD OUT is the road in: deactivate by governed agreement, after
--     which the fabricated citation seals — with ONE proof row. No agreement,
--     no mark: absence of the obligation proof is itself legible.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; v_sha text; n int;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_proof_obligation', 'about','urn:ckp:s64-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('obligation','cite-real-surface', 'active','false')));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (5): propose rejected: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (5): vote rejected: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's64 FAIL (5): apply rejected: %', ap; END IF;
  v_sha := ckp.seal('s64-report-after', jsonb_build_object(
    'type','urn:ckp:s64-test/type/Report', '@id','urn:s64:report-after',
    'https://conceptkernel.org/ontology/v3.11/core#surfaceDigest', repeat('f',64)));
  IF v_sha IS NULL THEN RAISE EXCEPTION 's64 FAIL (5): post-deactivation seal returned null'; END IF;
  SELECT count(*) INTO n FROM ckp.proof WHERE about = 's64-report-after';
  IF n <> 1 THEN RAISE EXCEPTION 's64 FAIL (5): expected exactly 1 proof after deactivation, got %', n; END IF;
END $$;

\echo s64_proof_obligation: PASS
