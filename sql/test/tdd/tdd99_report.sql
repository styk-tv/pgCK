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
