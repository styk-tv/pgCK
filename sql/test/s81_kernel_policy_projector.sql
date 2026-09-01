-- s81_kernel_policy_projector.sql — THE LAW ENFORCES ITS OWN BOUNDS (0.4.95).
--
-- WHY THIS EXISTS. core declares seven Kernel policy properties and says of each
-- that it is "an OVERRIDE, sealed only through propose->vote->apply". No
-- projector could write a Kernel property, so the route the law mandates did not
-- exist: measured, zero kernels on any door carried any of the seven.
--
-- THE DESIGN CLAIM THIS FILE DEFENDS: the projector checks NO ranges. Every bound
-- is already declared — weightAssent >= 0, weightDissent <= 0, weightImplicit in
-- [0,1], decayLambda >= 0, thresholdDefer >= 0, and thresholdDiscard sh:lessThan
-- thresholdPromote. A projector carrying its own copy would be a second
-- implementation of a rule that already exists, which is the defect class D-1
-- corrected one layer over. You do not enforce your own shape; you declare it,
-- and the ground refuses what violates it.
--
-- That claim is only worth anything if the ground REALLY refuses. Hence four
-- controls, not one, and the fourth is the one that matters most:
--   (a) POSITIVE  an in-range policy value conforms
--   (b) CONTROL   weightDissent POSITIVE is refused — a positive value inverts
--                 the meaning of every Score without changing its shape
--   (c) CONTROL   weightImplicit > 1 is refused — above 1 an implicit
--                 saw-but-didn't-vote signal outweighs an explicit vote
--   (d) CONTROL   thresholdDiscard >= thresholdPromote is refused. This is the
--                 ONLY cross-property invariant of the seven and the only one no
--                 per-property constraint can catch: both values are individually
--                 legal and together they inverted the bands, so everything
--                 discards and nothing promotes.
--   (e) CONTROL   an UNDECLARED field is refused BY NAME, not minted. An
--                 undeclared key is the silent failure this substrate exists to
--                 retire — it would seal, conform vacuously, and mean nothing.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  comp int; base text; ok boolean; r jsonb; kid text;
BEGIN
  comp := ckp._composed_shapes(ckp._project());
  IF comp IS NULL THEN RAISE EXCEPTION 's81: no composed surface — fixture problem, not a result'; END IF;

  -- A Kernel candidate carrying every REQUIRED property, so the policy bounds are
  -- what is being measured and not a missing label. hasOrgan is minCount 3 and is
  -- easy to miss: the first draft of this probe failed on it and looked like a
  -- bounds failure.
  base := '@prefix ckp: <'||C||'> . @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
           @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:s81/kernel> a ckp:Kernel ; rdfs:label "s81" ; ckp:epoch 0 ;
      ckp:inProject <urn:ckp:project:s81> ; ckp:transportSegment "s81" ;
      ckp:hasOrgan <urn:ckp:s81/organ/ck>, <urn:ckp:s81/organ/tool>, <urn:ckp:s81/organ/data> ';

  -- (a) POSITIVE
  ok := ckp.validate(base||'; ckp:weightAssent "1.0"^^xsd:decimal ; ckp:weightDissent "-0.8"^^xsd:decimal ; ckp:weightImplicit "0.3"^^xsd:decimal ; ckp:decayLambda "0.05"^^xsd:decimal .', comp);
  IF NOT ok THEN
    RAISE EXCEPTION 's81 FAIL (a): an IN-RANGE policy set does not conform — the gate refuses what the law permits, and every control below would pass for the wrong reason';
  END IF;
  RAISE NOTICE 's81 (a) PASS — in-range policy conforms';

  -- (b) CONTROL: dissent must be negative
  IF ckp.validate(base||'; ckp:weightDissent "0.5"^^xsd:decimal .', comp) THEN
    RAISE EXCEPTION 's81 FAIL (b): weightDissent +0.5 CONFORMED — a positive dissent weight makes disagreement raise a score, the one sign error that inverts every Score without changing its shape';
  END IF;
  RAISE NOTICE 's81 (b) PASS — positive weightDissent refused';

  -- (c) CONTROL: implicit is a ceiling <= 1
  IF ckp.validate(base||'; ckp:weightImplicit "1.5"^^xsd:decimal .', comp) THEN
    RAISE EXCEPTION 's81 FAIL (c): weightImplicit 1.5 CONFORMED — above 1 a saw-but-didn''t-vote signal outweighs an explicit vote';
  END IF;
  RAISE NOTICE 's81 (c) PASS — weightImplicit above 1 refused';

  -- (d) THE CONTROL THAT MATTERS: the cross-property invariant
  IF ckp.validate(base||'; ckp:thresholdPromote "0.5"^^xsd:decimal ; ckp:thresholdDiscard "0.9"^^xsd:decimal .', comp) THEN
    RAISE EXCEPTION 's81 FAIL (d): thresholdDiscard >= thresholdPromote CONFORMED — both values are individually legal and together they invert the bands so everything discards and nothing promotes. No per-property constraint can catch this; if it is gone, the projector must carry the check after all';
  END IF;
  RAISE NOTICE 's81 (d) PASS — inverted thresholds refused (cross-property invariant holds)';

  -- (e) CONTROL: an undeclared field is refused BY NAME, never minted
  -- ⚠ THE IDENTITY GATE FIRES FIRST, AND THE FIRST DRAFT OF THIS CONTROL PASSED
  -- BECAUSE OF IT. Without a declared requester, ckp.seal refuses the write as
  -- unattributed — a correct refusal, for a completely different reason than the
  -- one this control claims. Asserting only "it refused" made the check pass
  -- while proving nothing about undeclared keys. Name an identity so the
  -- undeclared-key gate is the one under test, and assert the REASON, not just
  -- the refusal.
  PERFORM set_config('ckp.requester', 'svc:s81-control', true);
  SELECT body->>'@id' INTO kid FROM ckp.instances
   WHERE body->>'type' = C||'Kernel' ORDER BY ts_created LIMIT 1;
  IF kid IS NOT NULL THEN
    r := ckp.update_typed(jsonb_build_object('id', kid,
           'patch', jsonb_build_object(C||'weightNonsense', 0.5)));
    IF (r->>'ok')::boolean IS TRUE THEN
      RAISE EXCEPTION 's81 FAIL (e): an UNDECLARED policy field was accepted — an undeclared key is minted, not refused, and would seal while meaning nothing';
    END IF;
    IF r->>'error' IS DISTINCT FROM 'undeclared_patch_key' THEN
      RAISE EXCEPTION 's81 FAIL (e): refused, but NOT for being undeclared — got %. A control that passes for the wrong reason is not a control', COALESCE(r->>'error','<null>');
    END IF;
    RAISE NOTICE 's81 (e) PASS — undeclared field refused BY NAME: % %', r->>'error', COALESCE(r->>'key','');
  ELSE
    RAISE NOTICE 's81 (e) SKIP — no sealed Kernel on this database to patch';
  END IF;
END $$;

\echo 's81 PASS — the law enforces its own policy bounds; the projector carries no copy'
