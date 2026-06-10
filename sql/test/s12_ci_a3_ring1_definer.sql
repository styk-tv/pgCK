-- s12_ci_a3_ring1_definer.sql — CI-A-3 test (SPEC.ROADMAP.v3.9.CHECKLIST index 23).
--
-- Acceptance (roadmap §4 / v3.9 §3): each Ring-1 primitive is SECURITY DEFINER with a
-- pinned search_path and owned by ck_substrate; a primitive runs pgrdf.* successfully
-- AS DEFINER while the caller role (ck_participant) cannot reach pgrdf.* directly.
--
-- Run: psql -U pgck -d pgck -v ON_ERROR_STOP=1 < sql/test/s12_ci_a3_ring1_definer.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- ---------------------------------------------------------------------------
-- (a) The frozen ten: exist, SECURITY DEFINER, pinned search_path, owned by ck_substrate.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  names text[] := ARRAY['_seal','_validate','_read_typed','_traverse','_verify',
                        '_materialize','_stage_parse','_graph_apply','_recompile','_ledger_read'];
  n text;
  r record;
  found int;
BEGIN
  FOREACH n IN ARRAY names LOOP
    SELECT count(*) INTO found
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'ckp' AND p.proname = n;
    IF found = 0 THEN
      RAISE EXCEPTION 's12 FAIL: Ring-1 primitive ckp.% is not defined', n;
    END IF;

    FOR r IN
      SELECT p.prosecdef,
             p.proconfig,
             pg_get_userbyid(p.proowner) AS owner
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
      WHERE ns.nspname = 'ckp' AND p.proname = n
    LOOP
      IF NOT r.prosecdef THEN
        RAISE EXCEPTION 's12 FAIL: ckp.% is not SECURITY DEFINER', n;
      END IF;
      IF r.proconfig IS NULL
         OR array_to_string(r.proconfig, ',') NOT LIKE '%search_path=%' THEN
        RAISE EXCEPTION 's12 FAIL: ckp.% has no pinned search_path (proconfig=%)', n, r.proconfig;
      END IF;
      IF r.owner <> 'ck_substrate' THEN
        RAISE EXCEPTION 's12 FAIL: ckp.% is owned by % (expected ck_substrate)', n, r.owner;
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- (b) Definer reach: grant ck_participant EXECUTE on the read primitive only.
--     The wrapper runs pgrdf.sparql as ck_substrate; ck_participant still cannot
--     call pgrdf.sparql directly (CI-A-4).
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION ckp._read_typed(text) TO ck_participant;

-- (b.1) direct pgrdf.sparql is still denied to ck_participant.
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE ck_participant;
    PERFORM pgrdf.sparql('ASK { ?s ?p ?o }');
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    RESET ROLE;
    RAISE EXCEPTION 's12 FAIL: ck_participant called pgrdf.sparql directly (Ring 0 leaked)';
  END IF;
END $$;

-- (b.2) the Ring-1 wrapper SUCCEEDS for ck_participant — it runs pgrdf as definer.
DO $$
DECLARE res jsonb; failed text;
BEGIN
  SET LOCAL ROLE ck_participant;
  BEGIN
    res := ckp._read_typed('ASK { ?s ?p ?o }');
  EXCEPTION WHEN OTHERS THEN
    failed := SQLERRM;
  END;
  RESET ROLE;

  IF failed IS NOT NULL THEN
    RAISE EXCEPTION 's12 FAIL: ckp._read_typed (SECURITY DEFINER) failed for ck_participant: %', failed;
  END IF;
  IF res IS NULL THEN
    RAISE EXCEPTION 's12 FAIL: ckp._read_typed returned NULL';
  END IF;
END $$;

RESET ROLE;

-- Cleanup: drop the probe grant so later tests see ck_participant as dispatch-only.
REVOKE EXECUTE ON FUNCTION ckp._read_typed(text) FROM ck_participant;

\echo s12_ci_a3_ring1_definer: PASS
