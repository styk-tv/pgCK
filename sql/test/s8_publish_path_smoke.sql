-- CKA-6 / S4 step 6 — SQL-side verification of the outbox publish path.
--
-- Acceptance (per _WIP/TASKS.PGCK.S4-BUNDLED-NATS.v0.1 step 6):
--   After sealing a Task via ckp.seal(), exactly one ckp.outbox row
--   appears with subject = 'event.kernel.pgCK.Task.sealed', headers
--   containing Ck-Seq matching the ledger.seq of the seal, payload
--   matching the body bytes.
--
-- This fixture exercises only the TRIGGER side of CKA-6 (step 4 SQL).
-- It does NOT test the bgworker drain (steps 3 + 5) — that requires a
-- running pgCK v0.2.1+ build inside the container, which is the
-- separate CKE-4 / bundle-rebuild path. When the bundle catches up
-- (post-NOTIFY response from oci-germination), this fixture verifies
-- end-to-end behaviour against a real bundle as-is: the outbox row
-- will appear AND get drained by the bgworker, leaving an empty
-- outbox + a NATS publish observable via a sibling subscriber.
--
-- Self-contained: loads ontology modules from the repo's ontology/
-- directory rather than relying on the runtime's /ontology mount.
--
-- Run: psql -f sql/test/s8_publish_path_smoke.sql

\set t `cat ontology/task.ttl`
\set g `cat ontology/goal.ttl`

SELECT pgrdf.add_graph('urn:ckp:s8-test/kernel/board') AS board_g \gset
SELECT pgrdf.clear_graph(:board_g);
SELECT pgrdf.parse_turtle(:'t', :board_g, 'urn:ckp:s8-test/module/task#');
SELECT pgrdf.parse_turtle(:'g', :board_g, 'urn:ckp:s8-test/module/goal#');
SELECT pgrdf.materialize(:board_g);

SET ckp.project = 's8-test';

-- Capture the pre-seal outbox baseline so we can assert exactly one
-- row was added by this seal (vs leftover state from earlier tests
-- against the same project).
SELECT count(*) AS pre_count FROM ckp.outbox WHERE subject LIKE 'event.kernel.pgCK.%' \gset

-- Seal the shared Goal first so the Task can reference it.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.7/Goal',
    'https://conceptkernel.org/ontology/v3.7/goal_id', 's8-goal',
    'https://conceptkernel.org/ontology/v3.7/title',  's8 smoke goal',
    'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-29T00:00:00Z'
  );
BEGIN
  PERFORM ckp.seal('S8-G', v_body);
END $$;

-- Seal the Task whose outbox row we'll assert on.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.7/Task',
    'https://conceptkernel.org/ontology/v3.7/task_id', 'S8-T-1',
    'https://conceptkernel.org/ontology/v3.7/title', 's8 smoke task',
    'https://conceptkernel.org/ontology/v3.7/part_of_goal', 's8-goal',
    'https://conceptkernel.org/ontology/v3.7/target_kernel', 'pgCK',
    'https://conceptkernel.org/ontology/v3.7/lifecycle_state', 'pending',
    'https://conceptkernel.org/ontology/v3.7/priority', 1,
    'https://conceptkernel.org/ontology/v3.7/queue_seq', 1,
    'https://conceptkernel.org/ontology/v3.7/created_at', '2026-05-29T00:00:00Z'
  );
BEGIN
  PERFORM ckp.seal('S8-T-1', v_body);
END $$;

-- Verify the outbox state after the seals.
DO $$
DECLARE
  v_added_count int;
  v_task_subject text;
  v_task_seq bigint;
  v_task_ck_seq text;
  v_task_content_type text;
  v_task_payload_len int;
  v_ledger_seq bigint;
BEGIN
  -- Two seals (Goal + Task) → two rows added.
  SELECT count(*) - :pre_count INTO v_added_count
  FROM ckp.outbox WHERE subject LIKE 'event.kernel.pgCK.%';
  IF v_added_count <> 2 THEN
    RAISE EXCEPTION 's8 FAIL: expected 2 new outbox rows (Goal + Task), got %', v_added_count;
  END IF;

  -- Inspect the Task row specifically.
  SELECT seq, subject, headers->>'Ck-Seq', headers->>'Content-Type', octet_length(payload), ledger_seq
  INTO v_task_seq, v_task_subject, v_task_ck_seq, v_task_content_type, v_task_payload_len, v_ledger_seq
  FROM ckp.outbox
  WHERE subject = 'event.kernel.pgCK.Task.sealed'
    AND payload::text LIKE '%S8-T-1%'
  ORDER BY seq DESC
  LIMIT 1;

  IF v_task_seq IS NULL THEN
    RAISE EXCEPTION 's8 FAIL: no outbox row found for the Task seal';
  END IF;

  IF v_task_subject <> 'event.kernel.pgCK.Task.sealed' THEN
    RAISE EXCEPTION 's8 FAIL: subject is %, expected event.kernel.pgCK.Task.sealed', v_task_subject;
  END IF;

  IF v_task_content_type <> 'application/json' THEN
    RAISE EXCEPTION 's8 FAIL: Content-Type is %, expected application/json (CKA-5 swaps later)', v_task_content_type;
  END IF;

  IF v_task_ck_seq IS NULL OR v_task_ck_seq = '' THEN
    RAISE EXCEPTION 's8 FAIL: Ck-Seq header missing or empty';
  END IF;

  IF v_task_ck_seq::bigint <> v_ledger_seq THEN
    RAISE EXCEPTION 's8 FAIL: Ck-Seq header (%) does not match ledger_seq (%)', v_task_ck_seq, v_ledger_seq;
  END IF;

  IF v_task_payload_len < 50 THEN
    RAISE EXCEPTION 's8 FAIL: payload byte length too small: %', v_task_payload_len;
  END IF;

  -- Also assert compute_publish_subject() for the known type URIs.
  IF ckp.compute_publish_subject('https://conceptkernel.org/ontology/v3.7/Task') <> 'event.kernel.pgCK.Task.sealed' THEN
    RAISE EXCEPTION 's8 FAIL: compute_publish_subject(Task) wrong';
  END IF;
  IF ckp.compute_publish_subject('https://conceptkernel.org/ontology/v3.7/Goal') <> 'event.kernel.pgCK.Goal.sealed' THEN
    RAISE EXCEPTION 's8 FAIL: compute_publish_subject(Goal) wrong';
  END IF;
  IF ckp.compute_publish_subject(NULL) <> 'event.kernel.pgCK.Instance.sealed' THEN
    RAISE EXCEPTION 's8 FAIL: compute_publish_subject(NULL) wrong';
  END IF;
  IF ckp.compute_publish_subject('not-a-uri') <> 'event.kernel.pgCK.not-a-uri.sealed' THEN
    RAISE EXCEPTION 's8 FAIL: compute_publish_subject(no-slash) wrong';
  END IF;
END $$;

\echo s8_publish_path_smoke: PASS
