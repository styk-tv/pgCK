-- tdd99_report.sql — print the obligation ledger. Exits 0 whatever it finds:
-- this is a status report to watch obligations flip, not a gate. It becomes a
-- gate the day every row is GREEN.
\set ON_ERROR_STOP 0
\pset border 2
SELECT id, state, probe, claim FROM tdd_result ORDER BY id;
\echo ''
SELECT state, count(*) AS obligations FROM tdd_result GROUP BY state ORDER BY 1;
\echo ''
\echo 'BROKEN rows, if any — these mean the TEST is wrong, not the substrate:'
SELECT id, reason FROM tdd_result WHERE state='BROKEN';

-- 0.4.109 — THE DAY ARRIVED. The harness's own contract (tdd00): "it becomes
-- a gate on the day every row is GREEN, and not before." Measured on the
-- compose rig AND on a virgin install: 24 GREEN, 0 RED, 0 BROKEN. From this
-- version a non-GREEN row is a REGRESSION and this report refuses, so the
-- ledger can never quietly slide back below the floor it reached.
DO $$
DECLARE n int; bad text;
BEGIN
  SELECT count(*), string_agg(id||'='||state, ', ') INTO n, bad
    FROM tdd_result WHERE state <> 'GREEN';
  IF n > 0 THEN
    RAISE EXCEPTION 'TDD LEDGER REGRESSION — % obligation(s) below the 0.4.109 floor: %', n, bad;
  END IF;
END $$;
