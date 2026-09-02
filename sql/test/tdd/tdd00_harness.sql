-- tdd00_harness.sql — THE THREE-STATE OBLIGATION SUITE (authored 2026-09-01).
--
-- Method, adopted verbatim from pgRDF's LIB/TDD line, which is the best worked
-- example this fleet has: state every obligation as a test authored to be RED
-- FIRST, so that the FAILURE IS THE SPECIFICATION. Nothing here has been made to
-- pass. Every obligation below either fails now for a stated reason, or is one of
-- the few already delivered and says so.
--
-- THREE STATES, and the third is the point:
--   GREEN   the claim holds, proven by BEHAVIOUR
--   RED     the claim fails FOR THE STATED REASON — this is a specification
--   BROKEN  it failed for some OTHER reason — the test itself is wrong, or the
--           substrate moved underneath it. BROKEN is never acceptable and is
--           mechanically distinguished from RED rather than eyeballed.
--
-- THE RULE THAT KEEPS THIS HONEST:
--   An obligation may be proven RED by an EXISTENCE probe — "no such function,
--   column, class or row" is a complete reason for failing.
--   An obligation may NOT flip to GREEN on an existence probe. Flipping requires
--   a BEHAVIOUR probe with its negative control: the positive case works AND the
--   case that should fail does fail. Otherwise a feature ships the moment someone
--   creates an empty function with the right name — which is exactly how 0.4.92
--   shipped a reaper that reaped nothing.
--
-- ⚠ DO NOT RUN CONCURRENTLY WITH smoke-s4. Measured 2026-09-01: running the
-- ledger while the gate was rebuilding the same database produced two BROKEN
-- rows — B-1 "deadlock detected" and E-3 "no sealed Kernel to patch" — because
-- the suite drops and recreates the extension underneath the probes. Neither was
-- a substrate defect and neither was a wrong test; both were contention. The
-- harness reported BROKEN rather than RED, which is correct: it could not tell
-- whether the claim held, and said so instead of guessing. Run this when the
-- gate is idle.
--
-- This file WAS a status report; since 0.4.109 it is a GATE. Every row went
-- GREEN on 2026-09-02 — measured on the compose rig and on a virgin install —
-- and tdd99_report now refuses on any non-GREEN row, so the ledger can never
-- quietly slide back below the floor it reached. New obligations are authored
-- RED here first, flipped by their fix, and join the floor when they flip.
\set ON_ERROR_STOP 0

DROP TABLE IF EXISTS tdd_result;
CREATE TEMP TABLE tdd_result(
  id        text PRIMARY KEY,
  claim     text NOT NULL,
  probe     text NOT NULL CHECK (probe IN ('existence','behaviour')),
  state     text NOT NULL CHECK (state IN ('GREEN','RED','BROKEN')),
  reason    text NOT NULL
);

CREATE OR REPLACE FUNCTION tdd(p_id text, p_claim text, p_probe text, p_state text, p_reason text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO tdd_result(id, claim, probe, state, reason)
  VALUES (p_id, p_claim, p_probe,
          -- the rule, enforced rather than documented: existence can prove RED,
          -- never GREEN. An existence probe claiming GREEN is itself BROKEN.
          CASE WHEN p_probe = 'existence' AND p_state = 'GREEN' THEN 'BROKEN' ELSE p_state END,
          CASE WHEN p_probe = 'existence' AND p_state = 'GREEN'
               THEN 'HARNESS VIOLATION: an existence probe cannot flip an obligation GREEN — '
                    'write the behaviour probe with its negative control. ('||p_reason||')'
               ELSE p_reason END)
  ON CONFLICT (id) DO UPDATE SET claim=EXCLUDED.claim, probe=EXCLUDED.probe,
                                 state=EXCLUDED.state, reason=EXCLUDED.reason;
$$;
