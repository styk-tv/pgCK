-- pgck 0.2.2 -> 0.2.3 — CI-A-4: the Ring-0 role-isolation floor (CKP v3.9 §7, Phase A).
-- SPEC.ROADMAP.v3.9.CHECKLIST index 24 (the first task; floor precedes capability).
--
-- The leak (v3.9 §1.2 "pgRDF callable by any connected role"): Postgres grants
-- EXECUTE on functions to PUBLIC by default, and the dev role connects broad. So
-- today any connected role can reach pgrdf.sparql/materialize/... and the ckp
-- internal tables — bypassing the seal floor (the F-H failure class). v3.9 §7
-- converts the NATS-only *convention* into a database *structure*.
--
-- After this migration:
--   * Two roles exist:
--       ck_substrate   — NOLOGIN; the Ring-1 owner and the ONLY role granted
--                        pgrdf.* + the ckp internals.
--       ck_participant — NOLOGIN capability role; the only role connections/agents
--                        receive. Here it gets ckp schema USAGE ONLY; CI-A-2 grants
--                        it EXACTLY ckp.dispatch and nothing else.
--   * pgrdf.*  is REVOKEd from PUBLIC and GRANTed only to ck_substrate.
--   * ckp.*    functions are REVOKEd from PUBLIC; ck_substrate operates them.
--   * ckp internal tables/sequences carry no PUBLIC DML/SELECT.
--   * Future ckp/pgrdf objects default-deny to PUBLIC (ALTER DEFAULT PRIVILEGES),
--     which also pre-floors the forthcoming ckp.plans (CI-C-4).
--
-- CI-A-2 adds the single `GRANT EXECUTE ON ckp.dispatch TO ck_participant`.
-- CI-A-3 rehomes the Ring-1 primitives as SECURITY DEFINER owned by ck_substrate.
--
-- Idempotent + re-runnable. Negative test: sql/test/s11_ci_a4_role_floor.sql.

-- ============================================================================
-- §1. Roles (guarded — roles are cluster-global, survive DROP EXTENSION)
-- ============================================================================
DO $cia4_roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ck_substrate') THEN
    CREATE ROLE ck_substrate NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ck_participant') THEN
    CREATE ROLE ck_participant NOLOGIN;
  END IF;
END
$cia4_roles$;

COMMENT ON ROLE ck_substrate   IS
  'pgCK Ring-1 owner; the ONLY role granted pgrdf.* and the ckp internals (CKP v3.9 §7 / CI-A-4). Non-login.';
COMMENT ON ROLE ck_participant IS
  'The only role connections/agents receive; granted EXACTLY ckp.dispatch in CI-A-2 (CKP v3.9 §7). Non-login capability role.';

-- ============================================================================
-- §2. Ring 0 (pgrdf) reachable ONLY via ck_substrate
-- ============================================================================
REVOKE ALL ON SCHEMA pgrdf FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgrdf FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE   ON SCHEMA pgrdf                   TO ck_substrate;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgrdf  TO ck_substrate;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf GRANT EXECUTE ON FUNCTIONS TO ck_substrate;

-- pgrdf's C functions read/write pgrdf's OWN storage with the INVOKER's rights: the
-- quad store pgrdf._pgrdf_quads + a per-graph LIST partition _pgrdf_quads_g<id> minted
-- at runtime, the dictionary, the graph catalog, and the dictionary sequence. So
-- ck_substrate — the sole pgrdf operator — also needs pgrdf's tables/sequences and
-- CREATE on the schema (to mint new partitions). PUBLIC gets none of it.
REVOKE ALL ON ALL TABLES    IN SCHEMA pgrdf FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pgrdf FROM PUBLIC;
GRANT  CREATE ON SCHEMA pgrdf                TO ck_substrate;
GRANT  ALL ON ALL TABLES    IN SCHEMA pgrdf  TO ck_substrate;
GRANT  ALL ON ALL SEQUENCES IN SCHEMA pgrdf  TO ck_substrate;
-- Partitions the installing role mints during boot/load auto-grant ck_substrate and
-- stay off PUBLIC; partitions ck_substrate mints itself are owned by it.
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf REVOKE ALL ON TABLES    FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf GRANT  ALL ON TABLES    TO ck_substrate;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgrdf GRANT  ALL ON SEQUENCES TO ck_substrate;

-- GRANT is not enough: pgrdf mints a per-graph LIST partition of _pgrdf_quads at runtime
-- (add_graph), and the seal SHACL gate mints a scratch graph per write — CREATE/ATTACH/DROP
-- of a partition requires OWNERSHIP of the partitioned parent. So ck_substrate — the sole
-- pgrdf operator (v3.9 §7, refined: grant ⇒ own for the engine's storage) — OWNS pgrdf's
-- tables/partitions/sequences. Reassign every one that exists now; ones ck_substrate mints
-- later it already owns, and it owns the parent so it can route/insert through it.
DO $reown$
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
$reown$;

-- ck_participant is deliberately NOT granted USAGE on schema pgrdf — Ring 0 is
-- unreachable to it even if a future migration mis-grants EXECUTE to PUBLIC.

-- ============================================================================
-- §3. ckp schema + functions: no PUBLIC; ck_substrate operates
-- ============================================================================
GRANT USAGE ON SCHEMA ckp TO ck_substrate;
GRANT USAGE ON SCHEMA ckp TO ck_participant;   -- so CI-A-2 can grant it ckp.dispatch

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp GRANT  EXECUTE ON FUNCTIONS TO ck_substrate;

-- ============================================================================
-- §4. ckp internal tables/sequences: no PUBLIC; ck_substrate operates
-- ============================================================================
-- At CREATE EXTENSION time only ckp.config + ckp.dictionary exist; the seal-path
-- tables (instances/ledger/proof/outbox) are created later inside
-- ckp.bootstrap_kernel(). ALTER DEFAULT PRIVILEGES pre-floors objects created by
-- the installing role; the helper below + the bootstrap hook (§5) guarantee the
-- floor on the runtime tables regardless of which role boots.
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp REVOKE ALL ON TABLES    FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp GRANT  ALL ON TABLES    TO ck_substrate;
ALTER DEFAULT PRIVILEGES IN SCHEMA ckp GRANT  ALL ON SEQUENCES TO ck_substrate;

CREATE OR REPLACE PROCEDURE ckp._enforce_internal_floor()
LANGUAGE plpgsql AS $floor$
BEGIN
  -- Single idempotent statement set: applies to EVERY table/sequence currently in
  -- schema ckp (config + dictionary now; instances/ledger/proof/outbox after
  -- bootstrap; plans after CI-C-4). No PUBLIC; ck_substrate is the operating role.
  REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM PUBLIC;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM PUBLIC;
  GRANT  ALL ON ALL TABLES    IN SCHEMA ckp TO ck_substrate;
  GRANT  ALL ON ALL SEQUENCES IN SCHEMA ckp TO ck_substrate;
END;
$floor$;

COMMENT ON PROCEDURE ckp._enforce_internal_floor() IS
  'CI-A-4: REVOKE PUBLIC + GRANT ck_substrate on all ckp internal tables/sequences. '
  'Idempotent; called by the 0.2.3 migration and re-called at the end of '
  'ckp.bootstrap_kernel() so the floor holds on the runtime-created tables.';

-- Apply now to the tables that already exist (config, dictionary) — inline rather
-- than via CALL so it runs cleanly inside the CREATE EXTENSION transaction.
REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM PUBLIC;
GRANT  ALL ON ALL TABLES    IN SCHEMA ckp TO ck_substrate;
GRANT  ALL ON ALL SEQUENCES IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- §5. Re-apply the floor at the end of bootstrap_kernel()
-- ============================================================================
-- instances/ledger/proof/outbox are created here at runtime, so the floor must be
-- (re-)applied after their creation to be robust to the ALTER DEFAULT PRIVILEGES
-- owner-role. Body is the v0.2.1 bootstrap_kernel + a trailing floor call.
CREATE OR REPLACE PROCEDURE ckp.bootstrap_kernel()
LANGUAGE plpgsql AS $bk$
BEGIN
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
  DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
  CREATE TRIGGER ckp_ledger_after_insert
    AFTER INSERT ON ckp.ledger
    FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();

  -- CI-A-4: floor the runtime-created tables (instances/ledger/proof/outbox).
  CALL ckp._enforce_internal_floor();
END;
$bk$;

-- ============================================================================
-- §6. Re-floor functions from PUBLIC (ADP is unreliable inside CREATE EXTENSION).
-- ============================================================================
-- The §2 REVOKE floored the functions that existed then; the helper + redefined
-- bootstrap_kernel above are created after it, so re-REVOKE to catch them. Every
-- later migration that creates ckp functions repeats this (its own §).
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
