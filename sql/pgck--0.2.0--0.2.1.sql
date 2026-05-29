-- pgCK 0.2.0 -> 0.2.1 upgrade — CKA-6 / S4 step 4
--
-- Adds the outbox table + AFTER INSERT trigger on ckp.ledger that
-- enqueues every governed write for NATS publication by the bgworker.
-- Purely additive — ckp.seal() is unchanged; the trigger fires after
-- the seal's ledger insert, inside the same transaction.
--
-- Architecture per _WIP/SPEC.CKP.v3.8-rc-09-nats §2 (revised 2026-05-29)
-- and _WIP/TASKS.PGCK.S4-BUNDLED-NATS.v0.1 steps 3+4. Outbox owns the
-- in-process PG-backend -> bgworker IPC bridge; JetStream owns
-- cluster-level durability (handled in the bgworker's nats_client
-- publish_js arm when `pgck.nats_js_stream` GUC is non-empty).

-- ---- ckp.outbox: publish queue ----
--
-- Rows are written by the AFTER INSERT trigger on ckp.ledger and
-- drained by the bgworker tick loop via:
--
--   DELETE FROM ckp.outbox WHERE seq IN (
--     SELECT seq FROM ckp.outbox ORDER BY seq LIMIT 100
--   ) RETURNING seq, subject, payload, headers;
--
-- Atomic drain; rows that fail to publish stay in the table for the
-- next tick to retry. `attempt_count` is incremented by the drain
-- when a row is fetched but the publish fails; after a bounded number
-- of attempts (TBD policy) the row is logged + deleted. For v0.2.1
-- the drain is best-effort retry; no hard limit yet.

CREATE TABLE IF NOT EXISTS ckp.outbox (
  seq           BIGSERIAL PRIMARY KEY,
  ledger_seq    BIGINT NOT NULL REFERENCES ckp.ledger(seq) ON DELETE CASCADE,
  subject       TEXT NOT NULL,
  payload       BYTEA NOT NULL,
  headers       JSONB NOT NULL DEFAULT '{}'::jsonb,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  enqueued_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ckp_outbox_seq_idx ON ckp.outbox(seq);

COMMENT ON TABLE ckp.outbox IS
  'NATS publish queue. AFTER INSERT trigger on ckp.ledger writes rows here; '
  'bgworker tick loop drains via DELETE ... RETURNING and publishes to NATS. '
  'Lossy on permanent NATS failure (matches publish-edge model per rc-09-nats §4.2).';

-- ---- ckp.compute_publish_subject(type_uri) -> text ----
--
-- Derive the per-instance NATS subject from the body's type URI.
--   https://conceptkernel.org/ontology/v3.7/Task -> event.kernel.pgCK.Task.sealed
--   https://conceptkernel.org/ontology/v3.7/Goal -> event.kernel.pgCK.Goal.sealed
--   anything-else / null                         -> event.kernel.pgCK.Instance.sealed
--
-- Long-form subject family per CK.Lib.Js v1.3.10 wire contract
-- (SPEC.PGCK.NATS-CK-LIB-JS-ALIGNMENT.v0.2 §1.1). Short-form dual-emit
-- (CKA-7) lands separately.

CREATE OR REPLACE FUNCTION ckp.compute_publish_subject(p_type_uri TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT format(
    'event.kernel.pgCK.%s.sealed',
    COALESCE(
      NULLIF(regexp_replace(COALESCE(p_type_uri, ''), '^.*[/#]', ''), ''),
      'Instance'
    )
  );
$$;

COMMENT ON FUNCTION ckp.compute_publish_subject(text) IS
  'Map an instance type URI to its event.kernel.pgCK.<class>.sealed subject. '
  'Used by the ckp.ledger_to_outbox trigger; CKA-6 / v0.2.1.';

-- ---- ckp.ledger_to_outbox trigger function ----
--
-- Fires AFTER INSERT on ckp.ledger inside the same transaction as the
-- ckp.seal() call. Reads the instance body (already inserted at step 2
-- of seal — guaranteed present), computes the publish subject, builds
-- the headers map with Ck-Seq stamped from the ledger seq, and queues
-- one outbox row. The transaction's atomicity guarantees the outbox
-- row only exists if the seal+ledger+proof committed.

CREATE OR REPLACE FUNCTION ckp.ledger_to_outbox()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_body JSONB;
BEGIN
  SELECT body INTO v_body FROM ckp.instances WHERE id = NEW.instance_id;
  IF v_body IS NULL THEN
    -- ledger row without a matching instance row should not happen
    -- (ckp.seal() inserts instance before ledger); skip rather than fail
    RETURN NEW;
  END IF;

  INSERT INTO ckp.outbox(ledger_seq, subject, payload, headers)
  VALUES (
    NEW.seq,
    ckp.compute_publish_subject(v_body->>'type'),
    convert_to(v_body::text, 'UTF8'),
    jsonb_build_object(
      'Ck-Seq',        NEW.seq::text,
      'Content-Type',  'application/json'
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION ckp.ledger_to_outbox() IS
  'AFTER INSERT trigger on ckp.ledger that enqueues one ckp.outbox row '
  'per governed seal. Stamps Ck-Seq: <ledger.seq> for CKClient v1.3 dedup. '
  'CKA-6 / v0.2.1.';

DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
CREATE TRIGGER ckp_ledger_after_insert
AFTER INSERT ON ckp.ledger
FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();

COMMENT ON TRIGGER ckp_ledger_after_insert ON ckp.ledger IS
  'Wire ckp.ledger insertions into the NATS publish outbox. CKA-6 / v0.2.1.';
