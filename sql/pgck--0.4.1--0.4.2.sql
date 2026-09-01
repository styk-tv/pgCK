-- pgck 0.4.1 -> 0.4.2 — INSTALL-FROM-ZERO COMPLETENESS.
-- Answers oci-germination's install-cascade NOTIFY (2026-06-11): on a VIRGIN cluster,
-- `CREATE EXTENSION pgck CASCADE` did not yield a functional governed dispatch — the
-- seal-path tables lived only inside ckp.bootstrap_kernel() (a manual CALL), their
-- ownership depended on who called it, the pgrdf floor could drift for objects minted
-- after CI-A-4 ran, and consumers were pushed into floor-breaching workarounds
-- (granting pgrdf to ck_participant). Gate: scripts/smoke-s34-fresh-install.sh —
-- a real ck_participant login on a fresh cluster reaches ok:true with ZERO manual steps.
--
-- This file is included LAST in the generated install script (src/lib.rs,
-- name = pgck_install_completeness), so its floor re-assert covers every object any
-- earlier file created, regardless of future insertions between them.

-- ============================================================================
-- §1 (asks 1+2) — the seal-path tables exist AT INSTALL, owned by ck_substrate
-- ============================================================================
-- Same shapes as ckp.bootstrap_kernel() (which remains, idempotent, for legacy
-- callers); IF NOT EXISTS keeps warm-volume upgrades safe. Creating them here means
-- CREATE EXTENSION is sufficient — no procedure CALL required before dispatch works.
CREATE TABLE IF NOT EXISTS ckp.instances (
  id TEXT PRIMARY KEY, body JSONB NOT NULL,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  ts_created TIMESTAMPTZ NOT NULL DEFAULT now(),
  ts_updated TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ckp.ledger (
  seq BIGSERIAL PRIMARY KEY, instance_id TEXT NOT NULL,
  body_sha256 TEXT NOT NULL, sig TEXT NOT NULL,
  prev_seq BIGINT, ts TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ckp.proof (
  id BIGSERIAL PRIMARY KEY, about TEXT NOT NULL,
  method TEXT NOT NULL, digest TEXT NOT NULL,
  verified_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
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
-- 0.4.80 — P9: THE COMPUTE QUEUE GETS A RETRY BOUND. ckp.materialize_job is a
-- LIVE path — materialize_drain_once() runs every bgworker tick and picks one
-- job FOR UPDATE SKIP LOCKED — with zero rows so far, so its missing bound has
-- never bitten. It would bite the first time an expensive materialization
-- fails: re-selected forever, starving every concept behind it, and at any tick
-- cadence that presents as THE LOOP WORKING. ckp.outbox has carried
-- attempt_count since it shipped; this is the same lesson, unlearned in the
-- table next to it.
ALTER TABLE IF EXISTS ckp.materialize_job ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE IF EXISTS ckp.materialize_job ADD COLUMN IF NOT EXISTS last_error TEXT;
-- 0.4.77 — the adoption pin ledger joins the install floor. It was created by
-- the 0.4.60--0.4.61 migration (warm path) and inside ckp.bootstrap_kernel()
-- (manual CALL), but the baseline flatten never carried the top-level CREATE —
-- so on a FRESH install the composer's pin read/write hit a missing relation:
-- fleet.adoptions hard-errored, and the SECOND Adoption seal died
-- mid-recomposition (the first succeeds; pins are only consulted once a module
-- composes). Measured 2026-08-20 on ociger-pg18-pgrdf-pgck-nats-micro:v0.2.4;
-- the fresh-install smoke passed throughout because it never sealed two
-- Adoptions — its gate now must. Same defect class as the 0.4.74 authority
-- mirror; the cure is the same: the completeness block is the ONE creation
-- site fresh installs can rely on.
CREATE TABLE IF NOT EXISTS ckp.adoption_pins (
  graph_iri    TEXT PRIMARY KEY,
  graph_digest TEXT NOT NULL,
  pinned_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS structural_digest TEXT;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS nodeshapes INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS properties INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS asserted INTEGER;
-- 0.4.101 — D-1 and E-1 JOIN THE INSTALL FLOOR.
--
-- Found by installing 0.4.100 into a VIRGIN database on pgck.localhost rather
-- than by running the gate again. D-1's `methods`/`canonical_digest` and E-1's
-- `surface_digest` were added inside ckp.bootstrap_kernel(), which is a manual
-- CALL — CREATE EXTENSION never runs it. So a fresh install shipped WITHOUT the
-- columns while every upgraded database had them, and both obligations reported
-- GREEN because they were measured on a database that had been upgraded.
--
-- This is the 0.4.77 lesson recurring in the same file: "the adoption pin ledger
-- joins the install floor... the baseline flatten never carried the top-level
-- CREATE". Same trap, two releases of mine, caught only because someone asked
-- for a virgin container instead of another gate run.
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS methods JSONB;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS canonical_digest TEXT;
ALTER TABLE ckp.kernel_epoch  ADD COLUMN IF NOT EXISTS surface_digest TEXT;
DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
CREATE TRIGGER ckp_ledger_after_insert
  AFTER INSERT ON ckp.ledger
  FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();
-- T6 (v0.4.13): the label-projection trigger feeds concept.match's governed search. Created here
-- because this is the LAST include that has just (re)created ckp.instances; ckp.project_instance_label
-- is defined in the 0.4.12--0.4.13 include above. Guarded so a partial upgrade can't fail the floor.
DROP TRIGGER IF EXISTS ckp_instances_label_project ON ckp.instances;
DO $$ BEGIN
  IF to_regprocedure('ckp.project_instance_label()') IS NOT NULL THEN
    EXECUTE 'CREATE TRIGGER ckp_instances_label_project AFTER INSERT OR UPDATE ON ckp.instances '
         || 'FOR EACH ROW EXECUTE FUNCTION ckp.project_instance_label()';
  END IF;
END $$;

-- Ownership lands with creation (ALTER TABLE OWNER also moves the serial sequences),
-- so the SECURITY DEFINER subject operates its own tables — no call-time dependency.
ALTER TABLE ckp.instances     OWNER TO ck_substrate;
ALTER TABLE ckp.ledger        OWNER TO ck_substrate;
ALTER TABLE ckp.proof         OWNER TO ck_substrate;
ALTER TABLE ckp.outbox        OWNER TO ck_substrate;
ALTER TABLE ckp.adoption_pins OWNER TO ck_substrate;

-- Extension-created tables are excluded from pg_dump unless flagged: seal data is USER
-- data and must survive a dump/restore. Guarded (best-effort) — on a tree where the
-- tables pre-exist as non-members, dumpability is already the default and this no-ops.
-- 0.4.80 — THE LEDGER GETS A KEY OF ITS OWN. ckp.seal signs every ledger entry
-- hmac(body_sha256, identity_key) and reads this exact slot; the slot was
-- DESIGNED IN and never populated, so ckp.dispatch grew a COALESCE default of
-- the literal 'pgck-localhost' — our dev bench's own name — to make sealing
-- work. Measured 2026-08-21 on the latest published bundle: every deployment
-- was signing its proof chain with that same public string, so `verified: true`
-- meant "hashes correctly under a key everyone knows".
--
-- MINTING IS NOT DEFAULTING. A default hands every install the SAME answer; a
-- mint hands each one ITS OWN, so the value is specific by construction and
-- cannot be wrong-but-plausible. 32 bytes from pgcrypto, which is already a
-- hard dependency (CREATE EXTENSION pgck CASCADE pulls it).
INSERT INTO ckp.config(k, v)
SELECT 'identity_key', encode(gen_random_bytes(32), 'hex')
 WHERE NOT EXISTS (SELECT 1 FROM ckp.config WHERE k = 'identity_key');

DO $dump_042$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump('ckp.instances', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.ledger', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.ledger_seq_seq', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.proof', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.proof_id_seq', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.outbox', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.outbox_seq_seq', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.adoption_pins', '');
  -- 0.4.80 — ckp.config CARRIES THE SIGNING KEY, so it must survive a
  -- dump/restore or a restore brings back every sealed fact and loses the key
  -- that signs them: history restored, proofs unverifiable. (Until 0.4.80 this
  -- was masked because the key was a constant every install shared.)
  PERFORM pg_catalog.pg_extension_config_dump('ckp.config', '');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pgck 0.4.2: pg_extension_config_dump skipped (%, non-member tables already dumpable)', SQLERRM;
END
$dump_042$;

-- ============================================================================
-- §1.5 — virgin-DB seal path: an absent ontology is VALID SILENCE, not an error
-- ============================================================================
-- The cascade's real trap: the seal pre-flight PERFORMs ckp.shapes_self_test(project),
-- which RAISEd whenever the project board graph had never been imported — so on a
-- fresh cluster EVERY governed write failed until the consumer discovered
-- import_module + the /ontology mount. Doctrinally (VISION §2.1) a constraint that
-- was never declared is valid silence: with no board ontology loaded there is nothing
-- to self-test, and the SHACL gate engages the moment the modules ARE imported. The
-- stale-mount assert (the test's actual purpose) is kept verbatim for present graphs.
CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text)
RETURNS TABLE (shape_class text, target_class text, present boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'ckp','public','pg_temp'
AS $sst$
DECLARE
  v_comp_iri text := format('urn:ckp:%s/shapes/composed', p_project);
  v_iri      text;
  v_row      record;
  v_n        int := 0;
BEGIN
  -- 0.4.40: the ('ckp:TaskShape','ckp:Task') enumeration is RETIRED. This copy
  -- runs LAST on a fresh install (pgck_install_completeness), so leaving it here
  -- silently overwrote the baseline's corrected body — measured: CREATE EXTENSION
  -- kept demanding TaskShape while the upgrade route had already stopped.
  -- Hardcoded shape names are a second enforcement surface (SPEC.CKP.v3.11 §4.4).
  -- What survives is the one property a SHACL validator cannot report about
  -- itself: that it validated against NOTHING. Non-mutating by design.
  v_iri := CASE WHEN pgrdf.graph_id(v_comp_iri) IS NOT NULL
                THEN v_comp_iri ELSE 'urn:ckp:core' END;
  FOR v_row IN
    SELECT j->>'s' AS s, j->>'tc' AS tc
    FROM pgrdf.sparql(format(
      'PREFIX sh: <http://www.w3.org/ns/shacl#> PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> SELECT ?s ?tc FROM <%s> WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass ?tc }', v_iri)) j
  LOOP
    shape_class := v_row.s; target_class := v_row.tc; present := true;
    v_n := v_n + 1; RETURN NEXT;
  END LOOP;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'ckp.shapes_self_test: % targets NO class - the surface is VACUOUS. A validation against it would report conforms:true having evaluated nothing. Check the ontology mount and that ckp.boot() ran.', v_iri;
  END IF;
END;
$sst$;

COMMENT ON FUNCTION ckp.shapes_self_test(text) IS
  'Stale-ontology-mount guard. v0.4.2: an unimported board graph is valid silence '
  '(NOTICE + empty result) so a virgin cluster dispatches out of the box; a PRESENT '
  'board graph still hard-asserts the expected shapes.';

-- ============================================================================
-- §2 (ask 4) — re-assert the pgrdf floor for ck_substrate (and ONLY ck_substrate)
-- ============================================================================
-- CI-A-4 floored pgrdf at its point in the script; graphs/partitions minted later
-- (boot/load/upgrades run by the installing role) can drift. Re-own + re-grant
-- everything that exists NOW, idempotently. ck_participant deliberately gets NOTHING
-- here — a consumer granting pgrdf to ck_participant is breaching the v3.9 floor.
REVOKE ALL ON SCHEMA pgrdf FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgrdf FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA pgrdf FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pgrdf FROM PUBLIC;
GRANT USAGE   ON SCHEMA pgrdf                  TO ck_substrate;
GRANT CREATE  ON SCHEMA pgrdf                  TO ck_substrate;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgrdf TO ck_substrate;
GRANT ALL     ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
GRANT ALL     ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
DO $reown_042$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgrdf' AND c.relkind IN ('r','p','S')
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE pgrdf.%I OWNER TO ck_substrate', r.relname);
    ELSE
      EXECUTE format('ALTER TABLE pgrdf.%I OWNER TO ck_substrate', r.relname);
    END IF;
  END LOOP;
END
$reown_042$;

-- ============================================================================
-- §3 (ask 5) — the closing floor re-assert: every ckp callable, uniformly
-- ============================================================================
-- FUNCTIONS: SECURITY DEFINER, owned by ck_substrate, pinned search_path — the Ring-1
-- discipline applied to the WHOLE schema (legacy seal/validate/verify and the dispatch
-- chain included), so no inner call ever executes with caller rights.
-- PROCEDURES: owned + pinned search_path but kept SECURITY INVOKER — boot()/
-- import_module() use pg_read_file, which requires the (superuser) caller's rights;
-- their unqualified statements now resolve into ckp first regardless of caller config.
DO $floor_042$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT pr.oid, pr.prokind
    FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.prokind IN ('f','p')
  LOOP
    IF p.prokind = 'f' THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    ELSE
      EXECUTE format('ALTER PROCEDURE %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER PROCEDURE %s SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    END IF;
  END LOOP;
END
$floor_042$;

-- ============================================================================
-- §4 — the participant capability, re-pinned EXACTLY
-- ============================================================================
-- ck_participant holds: schema USAGE + EXECUTE on the dispatch door(s). Nothing else —
-- not the internals, not the tables, not pgrdf. Re-derived from scratch here so any
-- accidental grant in an earlier file (or on a consumer's cluster) is corrected.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM ck_participant;
REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM ck_participant;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM ck_participant;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
GRANT  ALL ON ALL TABLES    IN SCHEMA ckp TO ck_substrate;
GRANT  ALL ON ALL SEQUENCES IN SCHEMA ckp TO ck_substrate;
GRANT  USAGE ON SCHEMA ckp TO ck_participant;
-- v0.4.28 fresh-install ring repair (measured 2026-08-08): the two grants
-- below existed on every long-lived bench and in NO install file. The ring-1
-- definer set resolves ckp.* as ck_substrate, and the outbox drain connects
-- as ck_drainer — without schema USAGE both fail from zero with 'permission
-- denied for schema ckp' at the first seal / first drain, while table and
-- function grants above all succeed. ckp._enforce_internal_floor re-asserts
-- the same pair on every floor pass.
GRANT  USAGE ON SCHEMA ckp TO ck_substrate;
GRANT  USAGE ON SCHEMA ckp TO ck_drainer;
DO $door_042$
DECLARE p record;
BEGIN
  -- every ckp.dispatch overload is the door; everything else stays closed.
  FOR p IN
    SELECT pr.oid
    FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.proname = 'dispatch' AND pr.prokind = 'f'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ck_participant', p.oid::regprocedure);
  END LOOP;
END
$door_042$;

COMMENT ON TABLE ckp.instances IS
  'Sealed instances. Created at CREATE EXTENSION (v0.4.2 install-from-zero); owned by '
  'ck_substrate; reachable only through ckp.dispatch.';
