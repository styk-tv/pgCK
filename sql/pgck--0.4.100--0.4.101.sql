-- pgck 0.4.100 -> 0.4.101
--
-- D-1 AND E-1 JOIN THE INSTALL FLOOR — a fresh install was missing both.
--
-- Found by installing 0.4.100 into a VIRGIN database on pgck.localhost, which is
-- the only reason it was found at all. D-1's adoption_pins.methods /
-- .canonical_digest and E-1's kernel_epoch.surface_digest were added inside
-- ckp.bootstrap_kernel(), a procedure that is CALLed manually. CREATE EXTENSION
-- never calls it. So:
--
--   upgraded database  -> columns present, obligations GREEN
--   virgin install     -> columns ABSENT, and nothing said so
--
-- Both obligations reported GREEN throughout because both were measured on a
-- database that had been upgraded. `just smoke-s34` exists to test install from
-- zero and passed every run — it never asserted these columns, so a gate written
-- for exactly this class of defect did not catch this instance of it.
--
-- The same trap is documented in this very file at 0.4.77: "the adoption pin
-- ledger joins the install floor... the baseline flatten never carried the
-- top-level CREATE". Two releases of mine repeated it.
--
-- Upgrade path (this file) is a no-op for anyone who already ran the warm ALTERs;
-- IF NOT EXISTS makes it safe either way. The install path is fixed in
-- sql/pgck--0.4.1--0.4.2.sql, which is pgck_install_completeness and ships LAST.
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS methods JSONB;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS canonical_digest TEXT;
ALTER TABLE ckp.kernel_epoch  ADD COLUMN IF NOT EXISTS surface_digest TEXT;
