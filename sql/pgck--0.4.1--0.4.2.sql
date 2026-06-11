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
DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
CREATE TRIGGER ckp_ledger_after_insert
  AFTER INSERT ON ckp.ledger
  FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();

-- Ownership lands with creation (ALTER TABLE OWNER also moves the serial sequences),
-- so the SECURITY DEFINER subject operates its own tables — no call-time dependency.
ALTER TABLE ckp.instances OWNER TO ck_substrate;
ALTER TABLE ckp.ledger    OWNER TO ck_substrate;
ALTER TABLE ckp.proof     OWNER TO ck_substrate;
ALTER TABLE ckp.outbox    OWNER TO ck_substrate;

-- Extension-created tables are excluded from pg_dump unless flagged: seal data is USER
-- data and must survive a dump/restore. Guarded (best-effort) — on a tree where the
-- tables pre-exist as non-members, dumpability is already the default and this no-ops.
DO $dump_042$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump('ckp.instances', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.ledger', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.ledger_seq_seq', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.proof', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.proof_id_seq', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.outbox', '');
  PERFORM pg_catalog.pg_extension_config_dump('ckp.outbox_seq_seq', '');
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
CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text DEFAULT 'demo')
RETURNS TABLE (shape_class text, target_class text, present boolean)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $sst$
DECLARE
  v_board_iri text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g   bigint := pgrdf.graph_id(v_board_iri);
  v_q         text;
  v_row       record;
  v_ask       text;
  v_missing   text[] := ARRAY[]::text[];
BEGIN
  IF v_board_g IS NULL THEN
    -- v0.4.2: no board ontology imported for this project — nothing loaded, nothing
    -- stale to guard. The gate arms itself when ckp.import_module() lands the shapes.
    RAISE NOTICE 'ckp.shapes_self_test: board graph % not imported yet — self-test skipped (valid silence; import task/goal modules to arm the board gate)', v_board_iri;
    RETURN;
  END IF;

  FOR v_row IN
    SELECT * FROM (VALUES
      ('ckp:TaskShape', 'ckp:Task'),
      ('ckp:GoalShape', 'ckp:Goal')
    ) AS expected(shape, target)
  LOOP
    v_q := format(
      'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
       PREFIX sh:  <http://www.w3.org/ns/shacl#>
       PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
       ASK FROM <%s>
       WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass %s }',
      v_board_iri, v_row.target);

    shape_class  := v_row.shape;
    target_class := v_row.target;
    SELECT j->>'_ask' INTO v_ask FROM pgrdf.sparql(v_q) j LIMIT 1;
    present := COALESCE(v_ask = 'true', false);
    IF NOT present THEN
      v_missing := array_append(v_missing, v_row.shape);
    END IF;
    RETURN NEXT;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'ckp.shapes_self_test: missing % shape(s) in %; check /ontology mount is current',
      v_missing, v_board_iri;
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
