-- pgck 0.4.40 -> 0.4.41
--
-- A GATE REFUSAL MUST NOT TAKE THE TRANSPORT WITH IT.
--
-- Measured 2026-08-11 22:35:47 on pgck.localhost:
--   ckp.seal: payload fails the composed shape gate … NodeKindConstraintComponent
--   background worker "pgck-bridge" (PID 113) exited with exit code 1
--
-- The worker came up healthy at 21:42, served all evening, and died on the first
-- seal REFUSAL. With it dead nothing answers $SYS.REQ.USER.AUTH, so every
-- subsequent CONNECT is rejected with 'Authorization Violation' — the whole door
-- closes because the gate did its job. Both the MCP server and the CLI failed
-- identically, and a valid bearer made no difference.
--
-- Mechanism: ckp.seal RAISEs. Inside the bgworker's SPI call that Postgres ERROR
-- unwinds as a pgrx PANIC rather than a Result::Err, so inbound_dispatch's
-- `match out { Err(e) => …ok:false… }` never runs and the worker process
-- terminates. A refusal is a NORMAL, EXPECTED event — R2 and the shape gate exist
-- to produce them — so it must be data, never a fault of the transport.
--
-- The catch belongs here rather than in Rust: a PL/pgSQL EXCEPTION block opens a
-- subtransaction, so the refusal rolls back cleanly on its own and the caller's
-- transaction survives. This also closes PASS-27 Filing 2 — the refusal now
-- REACHES the caller as {"ok":false,"error":…} instead of being lost and
-- presenting as a 60 s timeout.

CREATE OR REPLACE FUNCTION ckp._dispatch_safe(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  v_out := ckp.dispatch(p_verb, p_payload);
  RETURN v_out;
EXCEPTION
  WHEN OTHERS THEN
    -- The refusal is the RESULT. Carry the clause the gate named, plus SQLSTATE
    -- so a caller can tell a shape refusal from a transport fault, and keep the
    -- verb so a Trace-Id correlation still resolves. Never re-raise: re-raising
    -- is what killed the worker.
    RETURN jsonb_build_object(
      'ok',      false,
      'refused', true,
      'verb',    p_verb,
      'sqlstate', SQLSTATE,
      'error',   SQLERRM
    );
END;
$function$;

COMMENT ON FUNCTION ckp._dispatch_safe(text, jsonb) IS
  'Transport-safe wrapper over ckp.dispatch. A gate refusal is returned as data '
  '({ok:false, refused:true, sqlstate, error}) instead of raising, because an '
  'unhandled RAISE inside the bgworker SPI call unwinds as a pgrx panic and '
  'terminates the worker — taking the auth-callout responder with it and closing '
  'the door for every client (measured 2026-08-11, pgck-bridge exit code 1).';
