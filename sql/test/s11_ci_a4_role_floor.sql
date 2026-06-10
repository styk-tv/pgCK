-- s11_ci_a4_role_floor.sql — CI-A-4 negative test (SPEC.ROADMAP.v3.9.CHECKLIST index 24).
--
-- Acceptance (roadmap §4 / v3.9 §7 Phase A exit):
--   As ck_participant, every pgrdf.* call and every direct SELECT/DML on a ckp
--   internal table raises permission denied (SQLSTATE 42501).
--
-- The "negative test is first-class" for this epoch (roadmap §1): we prove the
-- DENIAL, not just that a happy path works. Each probe SET LOCAL ROLE ck_participant,
-- runs the forbidden statement, and REQUIRES insufficient_privilege.
--
-- Run (fresh extension already created + booted by the smoke harness):
--   psql -U pgck -d pgck -v ON_ERROR_STOP=1 < sql/test/s11_ci_a4_role_floor.sql

\set ON_ERROR_STOP 1

-- Ensure the seal-path tables exist (and are floored by the bootstrap hook).
CALL ckp.bootstrap_kernel();

-- ---------------------------------------------------------------------------
-- (a) Structural shape: the two roles exist and the floor's privilege shape holds.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ck_substrate') THEN
    RAISE EXCEPTION 's11 FAIL: role ck_substrate missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ck_participant') THEN
    RAISE EXCEPTION 's11 FAIL: role ck_participant missing';
  END IF;

  -- Ring 0 is unreachable to PUBLIC and to ck_participant.
  IF has_schema_privilege('public', 'pgrdf', 'USAGE') THEN
    RAISE EXCEPTION 's11 FAIL: PUBLIC still has USAGE on schema pgrdf (Ring 0 not floored)';
  END IF;
  IF has_schema_privilege('ck_participant', 'pgrdf', 'USAGE') THEN
    RAISE EXCEPTION 's11 FAIL: ck_participant has USAGE on schema pgrdf (Ring 0 reachable)';
  END IF;

  -- ck_participant CAN reach the ckp schema (so CI-A-2 can grant it ckp.dispatch),
  -- but holds no function/table privileges yet.
  IF NOT has_schema_privilege('ck_participant', 'ckp', 'USAGE') THEN
    RAISE EXCEPTION 's11 FAIL: ck_participant lacks USAGE on schema ckp (CI-A-2 could not grant dispatch)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- (b) pgrdf.* is denied to ck_participant (Ring 0 unreachable).
-- ---------------------------------------------------------------------------
DO $$
DECLARE denied boolean;
BEGIN
  denied := false;
  BEGIN
    SET LOCAL ROLE ck_participant;
    PERFORM pgrdf.sparql('ASK { ?s ?p ?o }');
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;   -- subtransaction rollback also reverts SET LOCAL ROLE
  END;
  IF NOT denied THEN
    RESET ROLE;
    RAISE EXCEPTION 's11 FAIL: ck_participant executed pgrdf.sparql (Ring 0 leaked)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- (c) Direct SELECT on every ckp internal table is denied to ck_participant.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  tbls text[] := ARRAY['instances','ledger','proof','outbox','config','dictionary'];
  t    text;
  denied boolean;
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    denied := false;
    BEGIN
      SET LOCAL ROLE ck_participant;
      EXECUTE format('SELECT 1 FROM ckp.%I LIMIT 1', t);
    EXCEPTION WHEN insufficient_privilege THEN
      denied := true;
    END;
    IF NOT denied THEN
      RESET ROLE;
      RAISE EXCEPTION 's11 FAIL: ck_participant could SELECT ckp.% (internal table leaked)', t;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- (d) Direct DML (INSERT) on a ckp internal table is denied to ck_participant.
-- ---------------------------------------------------------------------------
DO $$
DECLARE denied boolean;
BEGIN
  denied := false;
  BEGIN
    SET LOCAL ROLE ck_participant;
    INSERT INTO ckp.proof(about, method, digest) VALUES ('s11-probe','hmac+sha256','deadbeef');
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    RESET ROLE;
    RAISE EXCEPTION 's11 FAIL: ck_participant could INSERT into ckp.proof (internal DML leaked)';
  END IF;
END $$;

RESET ROLE;
\echo s11_ci_a4_role_floor: PASS
