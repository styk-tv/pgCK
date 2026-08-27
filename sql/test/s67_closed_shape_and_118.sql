-- s67_closed_shape_and_118.sql — pgRDF's deliverables brought into USE (0.4.71).
--
--   (1) A SHAPE CAN BE LOCKED AND ENFORCED: governed add_class with
--       closed:true — a body with only declared keys seals; a body carrying
--       ONE undeclared key REFUSES on sh:closed. Minted keys become refusals.
--   (2) THE ENVELOPE SURVIVES THE LOCK: the server-derived stamps and board
--       timestamps ride the default ignore list — a closed shape that forgot
--       them would refuse everything (the negative control that matters most).
--   (3) adoption.check consumes pgRDF#118: on engines with loader-side
--       recording the report carries sourceRecorded/sourceLoads/
--       sourceDigestMatch; on older engines it degrades honestly
--       (verifiable:false, the old reason). Either way the keys EXIST and the
--       completeness verdict names which world it measured.
--   (4) R-11 on the census: wave.signals states INCOMPLETE with its blind
--       spots declared; adoption.check states its verdict; both carry the
--       engine counters (or null → a reader must say UNKNOWN).
--   (5) An aborted door dispatch no longer poisons the next: after a REFUSED
--       create, an immediate create reusing the same fresh IRI family seals
--       clean (the _dispatch_safe reset).
--
-- Run (booted by the smoke): psql … < s67_closed_shape_and_118.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's67-test';

-- (1)+(2) the locked shape, through governance.
DO $$
DECLARE pr jsonb; vt jsonb; ap jsonb; piri text; res jsonb;
BEGIN
  pr := ckp.dispatch('kernel.propose_change', jsonb_build_object(
    'op','add_class', 'about','urn:ckp:s67-test/kernel/ck', 'requires_quorum',1,
    'detail', jsonb_build_object('class','urn:ckp:s67-test/type/Sealed',
      'closed','true',
      'properties', jsonb_build_array(jsonb_build_object('path','urn:ckp:s67-test/prop/name','minCount',1)))));
  IF (pr->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's67 FAIL (1): propose: %', pr; END IF;
  piri := pr->>'proposal_iri';
  vt := ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  IF (vt->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's67 FAIL (1): vote: %', vt; END IF;
  ap := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF (ap->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's67 FAIL (1): apply: %', ap; END IF;

  -- declared keys only → seals. The dispatch path adds board timestamps and
  -- the seal derives four stamps: all on the ignore list — this passing IS
  -- control (2), the envelope surviving the lock.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s67-test/type/Sealed', '@id','urn:s67:ok',
    'urn:ckp:s67-test/prop/name','within the contract'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's67 FAIL (2): a conformant body refused under the closed shape — the ignore list is wrong: %', res; END IF;

  -- ONE undeclared key → REFUSED on sh:closed. The mint era ends here.
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s67-test/type/Sealed', '@id','urn:s67:minted',
    'urn:ckp:s67-test/prop/name','valid part',
    'urn:ckp:s67-test/prop/UNDECLARED','this key was never declared'));
  IF (res->>'ok') IS NOT DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's67 FAIL (1): an undeclared key SEALED under a closed shape — sh:closed is not enforcing'; END IF;
  IF res->>'error' NOT ILIKE '%closed%' AND res->>'error' NOT ILIKE '%Closed%' THEN
    RAISE EXCEPTION 's67 FAIL (1): refused, but not by the closed-shape clause: %', res->>'error'; END IF;
END $$;

-- (5) the poison protection: the refusal above was an aborted subtransaction;
-- an immediate create reusing fresh IRIs from the same family must seal clean.
DO $$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('instance.create', jsonb_build_object(
    'type','urn:ckp:s67-test/type/Sealed', '@id','urn:s67:after-abort',
    'urn:ckp:s67-test/prop/name','sealed right after a refusal, no reset ritual'));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's67 FAIL (5): create after a refusal failed — the abort poisoned the next call: %', res; END IF;
END $$;

-- (3)+(4) the reports carry their new fields and their verdicts.
DO $$
DECLARE res jsonb; m jsonb;
BEGIN
  res := ckp.dispatch('adoption.check', '{}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's67 FAIL (3): adoption.check: %', res; END IF;
  IF NOT (res ? 'completeness') THEN RAISE EXCEPTION 's67 FAIL (4): adoption.check carries no completeness verdict'; END IF;
  FOR m IN SELECT jsonb_array_elements(res->'modules') LOOP
    IF NOT (m ? 'sourceDigestVerifiable') OR NOT (m ? 'sourceDigestMatch') OR NOT (m ? 'sourceRecorded') THEN
      RAISE EXCEPTION 's67 FAIL (3): module row lacks the #118 fields: %', m; END IF;
  END LOOP;

  -- 0.4.86 — THE GHOST-READ GUARD REACHES THIS FIXTURE (v312-tdd case 24;
  -- cklib PASS-2 ISSUE-8). s67-test adopts no wave module, so the census must
  -- now REFUSE module_not_adopted instead of answering about nothing. The old
  -- assertion here (a completeness verdict from an UNADOPTED kernel) was
  -- itself a ghost read — R-11's census contract is only measurable on a
  -- kernel that adopted the module; the refusal naming module + cure IS the
  -- honest census of this state.
  res := ckp.dispatch('wave.signals', '{}'::jsonb);
  IF (res->>'error') IS DISTINCT FROM 'module_not_adopted' THEN
    RAISE EXCEPTION 's67 FAIL (4): wave.signals on an unadopted kernel must refuse module_not_adopted, got %', res; END IF;
  IF (res->>'refused') IS DISTINCT FROM 'true' OR (res->>'sqlstate') IS NULL THEN
    RAISE EXCEPTION 's67 FAIL (4): module_not_adopted arrived untyped (no refused:true / sqlstate) — the envelope law missed it: %', res; END IF;
END $$;

\echo s67_closed_shape_and_118: PASS
