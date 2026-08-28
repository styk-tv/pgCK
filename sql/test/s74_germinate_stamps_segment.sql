-- s74_germinate_stamps_segment.sql — EMISSION AND SHAPE MOVE IN ONE ACT (0.4.88).
--
-- WHY THIS EXISTS. Root 97f97cb2… (2026-08-28) added ckp:transportSegment to
-- ckp:KernelShape with minCount 1. The constraint was right and shipped with a
-- negative control — which sealed a ckp:Kernel DIRECTLY with a SUPPLIED segment
-- and correctly fired sh:pattern. What it never exercised was the germinate path,
-- where the segment is ABSENT. ckp.germinate_kernel had not moved with the law,
-- so it sealed label/epoch/inProject/hasOrgan and no segment, and the kernel was
-- refused at its own composed-surface gate on MinCount, value null.
--
-- Germination was IMPOSSIBLE on every door carrying that root — for four days,
-- silently, because nobody germinates during a normal day. CK.Lib.Js found it by
-- going first (SPEC.CK-LIB-JS.v1.6.1-to-PGCK-4) and it cost them a full correct
-- attempt: per-door credential, verified connection, canonical id, projectKind
-- supplied. Everything right, refused by a gap between a shape and its emitter.
--
-- THE LESSON THIS FILE PINS. A shape that gates a type whose emission path cannot
-- produce its required properties is a TOTAL WRITE OUTAGE presenting as bad data.
-- Testing the constraint is not testing the path that must satisfy it. This test
-- exercises BOTH, and it fails if either half regresses.
--
-- Run against a database booted on a root carrying ckp:transportSegment. On an
-- older root (7de02b35…, e.g. the artifact bench) (b) cannot fire — that is not a
-- failure here, it is a different law, and the skip says so rather than passing.

-- STRUCTURE NOTE. Germination and its read-back are SEPARATE top-level statements
-- on purpose. Wrapped in one DO block they share a transaction, and instance.get
-- returns null for a seal that has not committed — which reads exactly like the
-- defect this test exists to catch. A test whose own transaction semantics can
-- fake its failure mode is worse than no test.

SELECT set_config('ckp.requester', 'svc:s74', false);

-- (a) POSITIVE — germinate. Display label deliberately UNLIKE the wire id.
SELECT ckp.germinate_kernel('s74-probe', 'S74 Display Name — Not The Wire Id', 'shared') AS s74_germinate;

-- (a cont) the sealed kernel, read back THROUGH THE DOOR
DO $$
DECLARE v_r jsonb; v_seg text; v_label text; v_has boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pgrdf._pgrdf_dictionary
                  WHERE lexical_value LIKE '%core#transportSegment') INTO v_has;
  IF NOT v_has THEN
    RAISE NOTICE 's74 SKIP — this root does not declare ckp:transportSegment. Not a pass: a different law.';
    RETURN;
  END IF;

  SELECT ckp.dispatch('instance.get',
           jsonb_build_object('id','urn:ckp:s74-probe/kernel')) INTO v_r;
  v_seg   := v_r->'instance'->'body'->>'https://conceptkernel.org/ontology/v3.11/core#transportSegment';
  v_label := v_r->'instance'->'body'->>'http://www.w3.org/2000/01/rdf-schema#label';

  IF v_seg IS NULL THEN
    RAISE EXCEPTION E's74 FAIL (a): the germinated kernel carries NO transportSegment.\nThis is the 0.4.88 defect returning — ckp.germinate_kernel stopped stamping it, so the kernel refuses at its own gate on MinCount. Fix the EMITTER, never ckp:KernelShape.';
  END IF;
  IF v_seg <> 's74-probe' THEN
    RAISE EXCEPTION E's74 FAIL (a): sealed transportSegment is %, expected ''s74-probe''.\nThe segment must be the CANONICAL project id — never the display label, never caller-supplied. Two names that can disagree is the defect this property closes.', v_seg;
  END IF;
  IF v_label = v_seg THEN
    RAISE EXCEPTION E's74 FAIL (a): label and segment are identical, so this run did not exercise the thing it claims. Use a display label UNLIKE the wire id.';
  END IF;
  RAISE NOTICE 's74 (a) PASS — segment % · label % — display form and wire form are separate facts', v_seg, v_label;
END $$;

-- (b) NEGATIVE CONTROL — the gate MUST NOT have been loosened to let the verb through.
DO $$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s74', false);
  SELECT ckp.dispatch('instance.create', jsonb_build_object(
           'type','https://conceptkernel.org/ontology/v3.11/core#Kernel',
           'label','s74 no segment',
           'inProject','urn:ckp:project:s74-probe',
           'epoch',0)) INTO v_r;
  IF COALESCE(v_r->>'ok','false') = 'true' THEN
    RAISE EXCEPTION E's74 FAIL (b): a ckp:Kernel WITHOUT transportSegment SEALED.\nThe gate was loosened to make (a) pass. (a) is fixed in the EMITTER, never by weakening ckp:KernelShape — otherwise the property is decorative and any client can mint an unreachable kernel.';
  END IF;
  IF v_r->>'error' NOT LIKE '%transportSegment%' THEN
    RAISE EXCEPTION E's74 FAIL (b): refused, but NOT on transportSegment: %\nThe refusal must name the clause that fired, or this control cannot tell which gate refused.', left(v_r->>'error', 300);
  END IF;
  RAISE NOTICE 's74 (b) PASS — direct seal without the property still refuses, naming the clause';
END $$;

-- (c) NEGATIVE CONTROL — plane A untouched: the procedural guard still refuses first.
DO $$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('ckp.requester', 'svc:s74', false);
  SELECT ckp.germinate_kernel('S74_Probe', NULL, 'shared') INTO v_r;
  IF COALESCE(v_r->>'ok','false') = 'true' THEN
    RAISE EXCEPTION E's74 FAIL (c): a NON-CANONICAL kernel id germinated. NATS has no case folding, so this mints a kernel nothing can seal into.';
  END IF;
  IF v_r->>'error' NOT LIKE '%not canonical%' THEN
    RAISE EXCEPTION E's74 FAIL (c): refused, but not by the canonical guard: %', left(v_r->>'error', 200);
  END IF;
  RAISE NOTICE 's74 (c) PASS — non-canonical id refused at the guard (plane A), slug named';
  RAISE NOTICE 's74 NOTE — (a) EMITTER · (b) SHAPE · (c) PROCEDURAL guard. Three planes, three gates. A green exercising only one of them is the gap that let 0.4.88 happen.';
END $$;

SELECT 's74_germinate_stamps_segment: PASS';
