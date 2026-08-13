-- s35_instance_retire.sql — instance.retire (the FINALIZED spec's last verb, built in v0.4.3).
--
-- The retraction seal: retiring an instance seals a NEW fact (retired:true + reason) — ledger
-- grows, proof verifies, the original fact stays in the chain. Confirms: a missing reason is
-- rejected; an unknown id is rejected; a valid retire seals + verifies; a second retire returns
-- already_retired; the instance is still readable (retired, not erased); the validate_report
-- by-IRI scratch fix still validates TTL (regression guard for the §2 redefine).
--
-- Run (booted by the smoke): psql … < s35_instance_retire.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

INSERT INTO ckp.instances(id, body) VALUES ('urn:ret:1', '{"type":"urn:test:Doc","title":"to retire"}'::jsonb)
  ON CONFLICT (id) DO UPDATE SET body=EXCLUDED.body;

-- (a) a reason is required.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.retire', '{"id":"urn:ret:1"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'reason_required' THEN RAISE EXCEPTION 's35 FAIL: missing reason not rejected: %', res; END IF;
END $$;

-- (b) unknown instance is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.retire', '{"id":"urn:ret:nope","reason":"x"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'unknown_instance' THEN RAISE EXCEPTION 's35 FAIL: unknown id not rejected: %', res; END IF;
END $$;

-- (c) a valid retire seals a NEW fact: ok, verified, ledger grew.
DO $$
DECLARE res jsonb; n0 bigint; n1 bigint;
BEGIN
  SELECT count(*) INTO n0 FROM ckp.ledger WHERE instance_id='urn:ret:1';
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.retire', '{"id":"urn:ret:1","reason":"superseded by urn:ret:2"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's35 FAIL: retire not ok: %', res; END IF;
  SELECT count(*) INTO n1 FROM ckp.ledger WHERE instance_id='urn:ret:1';
  IF n1 <= n0 THEN RAISE EXCEPTION 's35 FAIL: ledger did not grow (% -> %) — retirement was not SEALED', n0, n1; END IF;
  -- 0.4.55 TOLL, PAID DELIBERATELY. This used to assert the bare key
  -- `retired:true` — the OLD behaviour, in which the retraction path minted
  -- undeclared predicates and never moved the declared state (F15: a retired
  -- Proposal read proposalState "pending" to every other kernel forever). The
  -- golden pinned the loose behaviour; the tightening release trips it; the
  -- golden migrates to pin the DECLARED form. A retirement is real only in
  -- vocabulary another kernel can rely on: ckp:retiredAtEpoch + ckp:reason.
  IF (SELECT body->>'https://conceptkernel.org/ontology/v3.11/core#retiredAtEpoch'
        FROM ckp.instances WHERE id='urn:ret:1') IS NULL THEN
    RAISE EXCEPTION 's35 FAIL: body carries no ckp:retiredAtEpoch — retirement not declared'; END IF;
  IF (SELECT body->>'https://conceptkernel.org/ontology/v3.11/core#reason'
        FROM ckp.instances WHERE id='urn:ret:1') IS DISTINCT FROM 'superseded by urn:ret:2' THEN
    RAISE EXCEPTION 's35 FAIL: ckp:reason absent or wrong'; END IF;
  -- the bare key must be GONE: writing it was the defect, not a compatibility.
  IF (SELECT body ? 'retired' FROM ckp.instances WHERE id='urn:ret:1') THEN
    RAISE EXCEPTION 's35 FAIL: bare undeclared key `retired` still minted'; END IF;
END $$;

-- (d) you cannot retire twice (and the original fact is NOT erased — body still readable).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.retire', '{"id":"urn:ret:1","reason":"again"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'already_retired' THEN RAISE EXCEPTION 's35 FAIL: double retire not rejected: %', res; END IF;
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.get', '{"id":"urn:ret:1"}'::jsonb);
  RESET ROLE;
  IF res->'body'->>'title' <> 'to retire' THEN RAISE EXCEPTION 's35 FAIL: retired instance unreadable/erased: %', res; END IF;
END $$;

-- (e) regression: validate_report (now by-IRI scratch) still validates TTL.
DO $$
DECLARE rep jsonb;
BEGIN
  rep := ckp.validate_report('<urn:x:1> <urn:p:1> "v" .', (SELECT v::int FROM ckp.config WHERE k='core_graph_id'));
  IF rep->'conforms' IS NULL THEN RAISE EXCEPTION 's35 FAIL: validate_report broken after by-IRI fix: %', rep; END IF;
END $$;

\echo s35_instance_retire: PASS
