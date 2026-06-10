-- pgck 0.3.2 -> 0.3.3 — CKP v3.9 Track C (apply-time plan compiler + epoch invalidation).
-- This migration accretes Track C's SQL across CI-C-4 / CI-C-3 / CI-C-2; v0.3.3 ships at the
-- CI-C-1 flip. Track C eliminates F-H (stale-plan staleness): affordance query templates are
-- compiled — from the kernel's SEALED declarations, never caller input — into parameterized
-- statements at apply-time; runtime dispatch $1,$2-binds; a stale epoch forces recompile.

-- ============================================================================
-- CI-C-4 (index 15) — the ckp.plans table.
-- ============================================================================
-- v3.9 §5.3 / §9: compiled artifacts are DERIVED ENGINE STATE, deliberately NOT graph facts.
-- Keyed (kernel, verb, epoch); the apply-time compiler (CI-C-3) writes one parameterized plan
-- per affordance per epoch, and runtime dispatch binds params against it (never concatenates).

CREATE TABLE IF NOT EXISTS ckp.plans (
  kernel      text        NOT NULL,
  verb        text        NOT NULL,
  epoch       integer     NOT NULL,
  plan        jsonb       NOT NULL,   -- { kind, statement (with $1,$2…), params: [payload keys], … }
  compiled_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kernel, verb, epoch)
);

COMMENT ON TABLE ckp.plans IS
  'CI-C-4: compiled query plans — derived engine state (NOT graph facts; v3.9 §5.3). Keyed '
  '(kernel, verb, epoch). The apply-time compiler (CI-C-3) writes parameterized statements; '
  'runtime dispatch $1,$2-binds. A stale epoch forces recompile-then-retry (CI-C-2).';

-- floor: derived ckp internal state — never reachable by ck_participant (ADP is unreliable
-- inside CREATE EXTENSION, so REVOKE explicitly).
REVOKE ALL ON ckp.plans FROM PUBLIC;
GRANT  ALL ON ckp.plans TO ck_substrate;

-- ============================================================================
-- CI-C-3 (index 14) — the apply-time plan compiler.
-- ============================================================================
-- v3.9 §2.2(3)/§5.3: each affordance's internal query template — from the kernel's SEALED
-- declarations, never caller input — is compiled into a parameterized statement in ckp.plans
-- at genesis + every kernel.apply. Runtime resolves the plan for the kernel's current epoch
-- and binds the caller's values with EXECUTE … USING ($1,$2…) — it NEVER concatenates caller
-- input into SQL. The template text is pgCK-sealed; only the parameter VALUES come from the
-- caller, and they are bound, not interpolated.

-- The current compile epoch per kernel (CI-C-2 bumps it atomically with a type change).
CREATE TABLE IF NOT EXISTS ckp.kernel_epoch (
  kernel text    PRIMARY KEY,
  epoch  integer NOT NULL DEFAULT 1
);
REVOKE ALL ON ckp.kernel_epoch FROM PUBLIC;
GRANT  ALL ON ckp.kernel_epoch TO ck_substrate;

-- ckp.compile_plans(kernel) — (re)compile the kernel's sealed read templates into ckp.plans
-- at its current epoch. Idempotent (upsert by (kernel, verb, epoch)). The catalog below is
-- pgCK's sealed internal read surface; CI-E-2 extends this to kernel-declared ckp:sparql
-- query affordances compiled from the sealed kernel graph.
CREATE OR REPLACE FUNCTION ckp.compile_plans(p_kernel text DEFAULT 'pgCK')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $compile$
DECLARE
  v_epoch integer;
  v_n     integer := 0;
  r       record;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = p_kernel;

  FOR r IN
    SELECT * FROM (VALUES
      ('instance.get',
        '{"kind":"sql","statement":"SELECT body FROM ckp.instances WHERE id = $1","params":["id"]}'::jsonb),
      ('instance.count',
        '{"kind":"sql","statement":"SELECT count(*) AS n FROM ckp.instances","params":[]}'::jsonb)
    ) AS cat(verb, plan)
  LOOP
    INSERT INTO ckp.plans(kernel, verb, epoch, plan)
      VALUES (p_kernel, r.verb, v_epoch, r.plan)
      ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$compile$;

-- ckp.plan_exec(kernel, verb, payload) — resolve the plan at the kernel's CURRENT epoch and
-- run it with the caller's values bound positionally. EXECUTE … USING VARIADIC = parameterized
-- binding; the sealed statement text is never combined with caller input.
CREATE OR REPLACE FUNCTION ckp.plan_exec(p_kernel text, p_verb text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $exec$
DECLARE
  v_epoch  integer;
  v_plan   jsonb;
  v_stmt   text;
  v_wrap   text;
  v_np     integer;
  a1       text;
  a2       text;
  v_result jsonb;
BEGIN
  SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = p_kernel;
  v_epoch := COALESCE(v_epoch, 1);
  SELECT plan INTO v_plan FROM ckp.plans WHERE kernel = p_kernel AND verb = p_verb AND epoch = v_epoch;
  IF v_plan IS NULL THEN
    -- CI-C-2: a missing plan at the current epoch forces recompile-then-retry inside the call.
    PERFORM ckp.compile_plans(p_kernel);
    SELECT plan INTO v_plan FROM ckp.plans WHERE kernel = p_kernel AND verb = p_verb AND epoch = v_epoch;
  END IF;
  IF v_plan IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_plan', 'verb', p_verb, 'epoch', v_epoch);
  END IF;
  v_stmt := v_plan->>'statement';
  v_wrap := format('SELECT jsonb_agg(t) FROM (%s) t', v_stmt);
  v_np   := COALESCE(jsonb_array_length(v_plan->'params'), 0);
  -- caller VALUES only, in the plan's declared param order — bound, never concatenated.
  IF v_np >= 1 THEN a1 := p_payload->>(v_plan->'params'->>0); END IF;
  IF v_np >= 2 THEN a2 := p_payload->>(v_plan->'params'->>1); END IF;
  IF    v_np = 0 THEN EXECUTE v_wrap INTO v_result;
  ELSIF v_np = 1 THEN EXECUTE v_wrap INTO v_result USING a1;
  ELSIF v_np = 2 THEN EXECUTE v_wrap INTO v_result USING a1, a2;
  ELSE  RAISE EXCEPTION 'plan_exec: > 2 bound params not supported yet (verb %, np %)', p_verb, v_np;
  END IF;
  RETURN jsonb_build_object('ok', true, 'verb', p_verb, 'epoch', v_epoch,
                            'rows', COALESCE(v_result, '[]'::jsonb));
END;
$exec$;

ALTER FUNCTION ckp.compile_plans(text)              OWNER TO ck_substrate;
ALTER FUNCTION ckp.plan_exec(text, text, jsonb)     OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-C-2 (index 13) — epoch check + atomic invalidation (the F-H staleness fix).
-- ============================================================================
-- v3.9 §2.2(2): a type change bumps the kernel's compile epoch and recompiles its plans in
-- the SAME transaction, and clears the engine's SPARQL plan cache — so no caller can run
-- against a stale compiled plan. Runtime dispatch always resolves the CURRENT epoch (above),
-- and a missing plan recompiles-then-retries in-call (the plan_exec block above). Together:
-- the staleness window that was F-H is closed.

-- ckp.bump_epoch(kernel) — the _recompile primitive. One transaction: advance the epoch,
-- recompile plans at the new epoch, clear the pgRDF plan cache. Returns the new epoch.
CREATE OR REPLACE FUNCTION ckp.bump_epoch(p_kernel text DEFAULT 'pgCK')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $bump$
DECLARE v_epoch integer;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  UPDATE ckp.kernel_epoch SET epoch = epoch + 1 WHERE kernel = p_kernel RETURNING epoch INTO v_epoch;
  PERFORM ckp.compile_plans(p_kernel);   -- recompile at the new epoch (same txn)
  PERFORM pgrdf.plan_cache_clear();       -- invalidate the engine SPARQL plan cache (same txn)
  RETURN v_epoch;
END;
$bump$;

COMMENT ON FUNCTION ckp.bump_epoch(text) IS
  'CI-C-2: advance the kernel compile epoch + recompile plans + clear the pgRDF plan cache, '
  'atomically. Called on a sealed type change (CI-D kernel.apply wires this in).';

ALTER FUNCTION ckp.bump_epoch(text) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
