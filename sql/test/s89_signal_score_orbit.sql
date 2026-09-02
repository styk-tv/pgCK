-- s89_signal_score_orbit.sql — THE ARC THAT ACCUMULATES (0.4.109).
--
-- signal.boundary: one head per boundary, never per event; never-saw is a
-- free success. score.tick: derived under the kernel's law, DRAFT only, the
-- whole provenance chain resolving. orbit queue: crossings detect, the drain
-- is bounded and fair, a failing job parks.
\set ON_ERROR_STOP 1

DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        r jsonb; u jsonb; d jsonb; n int; ep0 int; ep1 int; votes0 int; votes1 int; g record;
        prev_proj text := current_setting('ckp.project', true);
BEGIN
  PERFORM set_config('ckp.requester','svc:s89',true);
  DELETE FROM ckp.orbit_job WHERE kernel LIKE 's89%';
  r := ckp.germinate_kernel('s89k','s89','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's89 FIXTURE FAIL — germination refused: %', r; END IF;
  u := ckp.update_typed(jsonb_build_object('id','urn:ckp:s89k/kernel','patch', jsonb_build_object(
        C||'thresholdPromote', 0.5, C||'thresholdDiscard', -0.9,
        C||'orbitPeriodSeconds', 600,
        C||'orbitAnchor', to_char(date_trunc('second', now() - interval '2 hours') AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))));
  IF (u->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's89 FIXTURE FAIL — law would not seal: %', u; END IF;
  PERFORM set_config('ckp.project','s89k',true);
  DELETE FROM ckp.instances WHERE body->>(C||'about') LIKE 'urn:cand:s89%';

  -- (a) one head per boundary; never-saw free.
  r := ckp.signal_boundary(jsonb_build_object('about','urn:cand:s89-hot','dwellMillis',5000,'events',9));
  IF (r->>'sealed')::boolean IS NOT TRUE OR (r->>'verified')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's89 (a) FAIL — boundary did not seal on the chain: %', r; END IF;
  SELECT count(*) INTO n FROM ckp.instances WHERE body->>'type'=C||'Signal' AND body->>(C||'about')='urn:cand:s89-hot';
  IF n <> 1 THEN
    RAISE EXCEPTION 's89 (a) FAIL — 9 events sealed % Signal(s), the head must be ONE', n; END IF;
  r := ckp.signal_boundary(jsonb_build_object('about','urn:cand:s89-hot','events',0));
  IF (r->>'sealed')::boolean IS TRUE OR r->>'reason' IS DISTINCT FROM 'never_saw' THEN
    RAISE EXCEPTION 's89 (a) FAIL — never-saw did not stay free: %', r; END IF;
  RAISE NOTICE 's89 (a) PASS — one head for nine events, chained; never-saw sealed nothing, as a success';

  -- (b) score under law, DRAFT only, chain resolves.
  PERFORM ckp.seal('s89-s1', jsonb_build_object('type',C||'Signal','@id','ckp://Signal#s89-s1',
    C||'about','urn:cand:s89-hot', C||'signalPolarity','assent'));
  SELECT COALESCE(epoch,0) INTO ep0 FROM ckp.kernel_epoch WHERE kernel='s89k';
  SELECT count(*) INTO votes0 FROM ckp.instances WHERE body->>'type'=C||'Vote';
  r := ckp.score_tick('s89k');
  SELECT COALESCE(epoch,0) INTO ep1 FROM ckp.kernel_epoch WHERE kernel='s89k';
  SELECT count(*) INTO votes1 FROM ckp.instances WHERE body->>'type'=C||'Vote';
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'drafted') < 1 THEN
    RAISE EXCEPTION 's89 (b) FAIL — the crossing did not draft: %', r; END IF;
  IF ep1 <> ep0 OR votes1 <> votes0 THEN
    RAISE EXCEPTION 's89 (b) FAIL — the tick moved what it may not (epoch %→%, votes %→%)', ep0, ep1, votes0, votes1; END IF;
  IF NOT EXISTS (SELECT 1 FROM ckp.instances p
                  WHERE p.body->>'type'=C||'Proposal' AND p.body->>(C||'about')='urn:cand:s89-hot'
                    AND p.body->>(C||'proposalState')='draft') THEN
    RAISE EXCEPTION 's89 (b) FAIL — no standing DRAFT for the crossed concept'; END IF;
  -- a second tick must NOT stack a second identical draft.
  r := ckp.score_tick('s89k');
  SELECT count(*) INTO n FROM ckp.instances p
   WHERE p.body->>'type'=C||'Proposal' AND p.body->>(C||'about')='urn:cand:s89-hot'
     AND p.body->>(C||'proposalState')='draft';
  IF n <> 1 THEN
    RAISE EXCEPTION 's89 (b) FAIL — % standing drafts for one concept: the tick generates pressure', n; END IF;
  RAISE NOTICE 's89 (b) PASS — crossed as DRAFT under the kernel''s law; epoch and votes untouched; one standing draft, not a queue of them';

  -- (c) orbit: detect once, drain fairly, park the failing.
  n := ckp.orbit_enqueue();
  IF NOT EXISTS (SELECT 1 FROM ckp.orbit_job WHERE kernel='s89k') THEN
    RAISE EXCEPTION 's89 (c) FAIL — the due crossing did not enqueue'; END IF;
  n := ckp.orbit_enqueue();
  SELECT count(*) INTO n FROM ckp.orbit_job WHERE kernel='s89k';
  IF n > 1 THEN RAISE EXCEPTION 's89 (c) FAIL — re-detection duplicated the crossing'; END IF;
  INSERT INTO ckp.orbit_job(kernel, crossing_at) VALUES ('s89ghost', now() - interval '1 hour');
  d := ckp.orbit_drain(4);
  IF NOT EXISTS (SELECT 1 FROM ckp.orbit_job WHERE kernel='s89k' AND state='done') THEN
    RAISE EXCEPTION 's89 (c) FAIL — the healthy kernel starved beside a failing ghost: %', d; END IF;
  d := ckp.orbit_drain(4); d := ckp.orbit_drain(4); d := ckp.orbit_drain(4); d := ckp.orbit_drain(4);
  SELECT * INTO g FROM ckp.orbit_job WHERE kernel='s89ghost';
  IF g.state IS DISTINCT FROM 'failed' OR g.attempt_count < 5 OR g.last_error IS NULL THEN
    RAISE EXCEPTION 's89 (c) FAIL — the failing job did not park with its error (state %, attempts %)', g.state, g.attempt_count; END IF;
  RAISE NOTICE 's89 (c) PASS — one detection, fair drain, the failing job parked at % attempts with its error kept', g.attempt_count;

  DELETE FROM ckp.orbit_job WHERE kernel LIKE 's89%';
  DELETE FROM ckp.instances WHERE body->>(C||'about') LIKE 'urn:cand:s89%' OR id LIKE 's89-%';
  PERFORM set_config('ckp.project',COALESCE(prev_proj,''),true);
END $$;

\echo 's89 PASS — one head per boundary, draft-only crossings under law, a queue that detects once and drains fairly'
