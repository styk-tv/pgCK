-- s31_ci_e3_transition_snapshot.sql — CI-E-3 (SPEC.ROADMAP.v3.9.CHECKLIST index 3).
--
-- instance.transition gate + authz'd snapshot. Confirms: a transition whose to_state is in the
-- sealed transition map seals the new state; an out-of-map transition is rejected; instance.snapshot
-- without a grant is denied (F-E closed) and succeeds with a grant; the legacy snapshot.board keeps
-- its un-gated behavior during the alias window.
--
-- Run (booted + kernel loaded by the smoke): psql … < s31_ci_e3_transition_snapshot.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

INSERT INTO ckp.instances(id, body) VALUES ('urn:doc:1', '{"type":"urn:test:Doc","state":"draft"}'::jsonb)
  ON CONFLICT (id) DO UPDATE SET body=EXCLUDED.body;

-- (a) a valid transition (draft → review) seals the new state.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', '{"id":"urn:doc:1","to_state":"review"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's31 FAIL: valid transition not ok: %', res; END IF;
  IF (SELECT body->>'state' FROM ckp.instances WHERE id='urn:doc:1') <> 'review' THEN RAISE EXCEPTION 's31 FAIL: state not updated to review'; END IF;
END $$;

-- (b) an out-of-map transition (review → done) is rejected.
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.transition', '{"id":"urn:doc:1","to_state":"done"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'invalid_transition' THEN RAISE EXCEPTION 's31 FAIL: invalid transition not rejected: %', res; END IF;
END $$;

-- (c) instance.snapshot WITHOUT a grant is denied (closes F-E).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.snapshot', '{"requester":"alice"}'::jsonb);
  RESET ROLE;
  IF res->>'error' <> 'snapshot_not_granted' THEN RAISE EXCEPTION 's31 FAIL: ungranted snapshot not denied: %', res; END IF;
END $$;

-- (d) WITH a grant, the snapshot succeeds.
DO $$
DECLARE res jsonb;
BEGIN
  INSERT INTO ckp.grants(grantee, permission) VALUES ('alice','snapshot') ON CONFLICT DO NOTHING;
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('instance.snapshot', '{"requester":"alice"}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's31 FAIL: granted snapshot not ok: %', res; END IF;
  IF (res->>'count')::int < 1 THEN RAISE EXCEPTION 's31 FAIL: snapshot empty: %', res; END IF;
END $$;

-- (e) the legacy snapshot.board still works (alias window — no grant required).
DO $$
DECLARE res jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  res := ckp.dispatch('snapshot.board', '{}'::jsonb);
  RESET ROLE;
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's31 FAIL: legacy snapshot.board broke: %', res; END IF;
END $$;

\echo s31_ci_e3_transition_snapshot: PASS
