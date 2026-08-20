-- pgck--0.4.76--0.4.77.sql — THE PIN LEDGER JOINS THE INSTALL FLOOR (P1, wave-v3.12 pass-v1).
--
-- MEASURED (2026-08-20, ociger-pg18-pgrdf-pgck-nats-micro:v0.2.4, fresh 0.4.76):
-- ckp.adoption_pins existed only in the 0.4.60--0.4.61 migration (warm path) and
-- inside ckp.bootstrap_kernel() (manual CALL) — the baseline flatten never carried
-- the top-level CREATE. On a fresh install the composer's pin read/write hit a
-- missing relation: fleet.adoptions hard-errored, and the SECOND Adoption seal
-- died mid-recomposition (the first succeeds; pins are consulted only once a
-- module composes). The fresh-install smoke passed throughout because it never
-- sealed two Adoptions — a check that cannot fail. Its gate now seals two.
--
-- The lasting fix is in the install-completeness block (pgck--0.4.1--0.4.2.sql,
-- the LAST include on every fresh install). This migration mirrors it for the
-- warm path so the two roads converge on one schema — the 5134c99 discipline:
-- the authority mirror and the baseline move in one act. Everything here is
-- idempotent; warm benches that already carry the table no-op through.

CREATE TABLE IF NOT EXISTS ckp.adoption_pins (
  graph_iri    TEXT PRIMARY KEY,
  graph_digest TEXT NOT NULL,
  pinned_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS structural_digest TEXT;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS nodeshapes INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS properties INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS asserted INTEGER;
ALTER TABLE ckp.adoption_pins OWNER TO ck_substrate;

-- Pins are runtime USER data (trust-on-first-sight records): survive dump/restore.
DO $dump_077$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump('ckp.adoption_pins', '');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pgck 0.4.77: pg_extension_config_dump skipped (%, non-member table already dumpable)', SQLERRM;
END $dump_077$;
