-- pgck 0.2.3 -> 0.2.4 — CI-A-3: the frozen Ring-1 primitive set (CKP v3.9 §3, Phase A).
-- SPEC.ROADMAP.v3.9.CHECKLIST index 23. Depends on CI-A-4 (the role floor / 0.2.3).
--
-- v3.9 §3 freezes ten pgCK-internal micro-operations as the ONLY functions permitted
-- to invoke pgrdf.* (and the ckp internals). This migration scaffolds all ten as
-- SECURITY DEFINER functions OWNED BY ck_substrate with a pinned search_path — so a
-- caller holding only ckp.dispatch reaches the engine solely through them, never
-- directly (CI-A-4 revoked the direct path).
--
--   1 _seal         wraps ckp.seal (the shipped 4-step txn)            [real]
--   2 _validate     pgrdf.validate(data_graph, shapes_graph) report   [real]
--   3 _read_typed   parameter-bound SELECT/ASK -> JSONB               [real (full plan-bind = CI-C/CI-E)]
--   4 _traverse     property-path read                                [stub -> CI-E-4 bounds it by path_max_depth]
--   5 _verify       wraps ckp.verify (ledger chain walk)              [real]
--   6 _materialize  pgrdf.materialize(graph)                          [real]
--   7 _stage_parse  pgrdf.parse_turtle(ttl, graph, base)             [real]
--   8 _graph_apply  pgrdf.copy_graph(src, dst)                        [real]
--   9 _recompile    plan compile + plan_cache_clear + epoch bump      [stub -> CI-C; pgrdf.plan_cache_clear is a later-pgRDF ask]
--  10 _ledger_read  proof/ledger reads -> JSONB                       [real]
--
-- Hygiene: SECURITY DEFINER + SET search_path = ckp, public, pg_temp on every one.
-- `public` is included because pgcrypto (digest/hmac/gen_random_uuid, used by
-- seal/verify) lives there; hardening (dedicated pgcrypto schema + qualified calls,
-- drop public) is a follow-up, not a Ring-1-shape change.
--
-- All pgrdf.* / ckp.* references are schema-qualified so the pinned search_path can
-- never be shadowed. Idempotent (CREATE OR REPLACE + guarded ALTER OWNER).
-- Test: sql/test/s12_ci_a3_ring1_definer.sql.

-- ============================================================================
-- §1. The ten Ring-1 primitives (CREATE OR REPLACE; owner reassigned in §2)
-- ============================================================================

-- 1) _seal — the write primitive (unchanged 4-step txn, behind the floor).
CREATE OR REPLACE FUNCTION ckp._seal(p_instance_id text, p_body jsonb)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN ckp.seal(p_instance_id, p_body);
END;
$$;

-- 2) _validate — SHACL gate over two graphs; returns the engine ValidationReport.
CREATE OR REPLACE FUNCTION ckp._validate(p_data_graph int, p_shapes_graph int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN pgrdf.validate(p_data_graph, p_shapes_graph);
END;
$$;

-- 3) _read_typed — parameter-bound SELECT/ASK projected to JSONB. The full
-- apply-time prepared-plan binding lands in CI-C/CI-E; here it is the typed read
-- primitive that already runs pgrdf as definer.
CREATE OR REPLACE FUNCTION ckp._read_typed(p_sparql text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(j) FROM pgrdf.sparql(p_sparql) j), '[]'::jsonb);
END;
$$;

-- 4) _traverse — property-path read (STUB). CI-E-4 bounds it by declared
-- predicates + pgrdf.path_max_depth (not in pgrdf 0.5.0). Today: a typed read.
CREATE OR REPLACE FUNCTION ckp._traverse(p_sparql text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  -- STUB: bounded traversal (via in declared predicates, depth <= path_max_depth)
  -- arrives in CI-E-4. Wraps pgrdf.sparql so the definer path is exercised now.
  RETURN COALESCE((SELECT jsonb_agg(j) FROM pgrdf.sparql(p_sparql) j), '[]'::jsonb);
END;
$$;

-- 5) _verify — ledger chain walk + HMAC + digest check.
CREATE OR REPLACE FUNCTION ckp._verify(p_instance_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN ckp.verify(p_instance_id);
END;
$$;

-- 6) _materialize — OWL-RL/RDFS inference over a graph (driven by sealed policy in
-- §5.4 later; never by a caller verb).
CREATE OR REPLACE FUNCTION ckp._materialize(p_graph int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  PERFORM pgrdf.materialize(p_graph);
END;
$$;

-- 7) _stage_parse — Rust Turtle parser into a (scratch) named graph. Governance
-- plane only (the fenced raw_ttl path, CI-D-2); never SQL string-building.
CREATE OR REPLACE FUNCTION ckp._stage_parse(p_ttl text, p_graph int, p_base text DEFAULT 'urn:ckp:stage#')
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN pgrdf.parse_turtle(p_ttl, p_graph, p_base);
END;
$$;

-- 8) _graph_apply — staging -> kernel graph copy (lifecycle UDF). The apply-time
-- mechanism for CI-D-3.
CREATE OR REPLACE FUNCTION ckp._graph_apply(p_src_graph int, p_dst_graph int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  PERFORM pgrdf.copy_graph(p_src_graph, p_dst_graph);
END;
$$;

-- 9) _recompile — plan compiler + plan_cache_clear + epoch bump (STUB). The real
-- body lands in CI-C (needs ckp.plans + a kernel epoch column, and
-- pgrdf.plan_cache_clear which is a later-pgRDF ask — not in 0.5.0). No-op now so
-- the frozen ring is complete and the apply cascade (CI-D-3) has its hook.
CREATE OR REPLACE FUNCTION ckp._recompile(p_kernel text DEFAULT 'demo')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RAISE DEBUG 'ckp._recompile(%): stub — plan compile + cache clear + epoch bump land in CI-C', p_kernel;
END;
$$;

-- 10) _ledger_read — proof/ledger reads, projected to JSONB (backs provenance).
CREATE OR REPLACE FUNCTION ckp._ledger_read(p_instance_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $$
BEGIN
  RETURN jsonb_build_object(
    'id', p_instance_id,
    'ledger', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'seq', seq, 'prev_seq', prev_seq, 'body_sha256', body_sha256, 'ts', ts) ORDER BY seq)
              FROM ckp.ledger WHERE instance_id = p_instance_id), '[]'::jsonb),
    'proof', (SELECT jsonb_build_object('digest', digest, 'method', method, 'verified_at', verified_at)
              FROM ckp.proof WHERE about = p_instance_id ORDER BY id DESC LIMIT 1));
END;
$$;

-- ============================================================================
-- §2. Reassign ownership to ck_substrate (so SECURITY DEFINER runs as the
--     Ring-1 owner, which alone holds pgrdf.* + the ckp internals — CI-A-4).
-- ============================================================================
ALTER FUNCTION ckp._seal(text, jsonb)              OWNER TO ck_substrate;
ALTER FUNCTION ckp._validate(int, int)             OWNER TO ck_substrate;
ALTER FUNCTION ckp._read_typed(text)               OWNER TO ck_substrate;
ALTER FUNCTION ckp._traverse(text)                 OWNER TO ck_substrate;
ALTER FUNCTION ckp._verify(text)                   OWNER TO ck_substrate;
ALTER FUNCTION ckp._materialize(int)               OWNER TO ck_substrate;
ALTER FUNCTION ckp._stage_parse(text, int, text)   OWNER TO ck_substrate;
ALTER FUNCTION ckp._graph_apply(int, int)          OWNER TO ck_substrate;
ALTER FUNCTION ckp._recompile(text)                OWNER TO ck_substrate;
ALTER FUNCTION ckp._ledger_read(text)              OWNER TO ck_substrate;

-- EXECUTE: PUBLIC is already denied by CI-A-4's ALTER DEFAULT PRIVILEGES. The owner
-- (ck_substrate) holds EXECUTE inherently; ckp.dispatch (CI-A-2, also definer-as-
-- ck_substrate) reaches them as the owner. No PUBLIC grant is added here.

COMMENT ON FUNCTION ckp._seal(text, jsonb)            IS 'Ring-1 (v3.9 §3 #1): the write primitive. SECURITY DEFINER as ck_substrate.';
COMMENT ON FUNCTION ckp._validate(int, int)           IS 'Ring-1 #2: SHACL gate -> ValidationReport. Definer.';
COMMENT ON FUNCTION ckp._read_typed(text)             IS 'Ring-1 #3: parameter-bound SELECT/ASK -> JSONB. Definer.';
COMMENT ON FUNCTION ckp._traverse(text)               IS 'Ring-1 #4: property-path read (stub -> CI-E-4). Definer.';
COMMENT ON FUNCTION ckp._verify(text)                 IS 'Ring-1 #5: ledger chain walk. Definer.';
COMMENT ON FUNCTION ckp._materialize(int)             IS 'Ring-1 #6: pgrdf.materialize. Definer.';
COMMENT ON FUNCTION ckp._stage_parse(text, int, text) IS 'Ring-1 #7: pgrdf.parse_turtle into staging. Definer.';
COMMENT ON FUNCTION ckp._graph_apply(int, int)        IS 'Ring-1 #8: pgrdf.copy_graph staging->kernel. Definer.';
COMMENT ON FUNCTION ckp._recompile(text)              IS 'Ring-1 #9: plan compile + cache clear + epoch bump (stub -> CI-C). Definer.';
COMMENT ON FUNCTION ckp._ledger_read(text)            IS 'Ring-1 #10: proof/ledger reads -> JSONB. Definer.';

-- ============================================================================
-- §3. Floor the new functions from PUBLIC (explicit — ADP is unreliable here).
-- ============================================================================
-- ALTER DEFAULT PRIVILEGES set in CI-A-4 does NOT reliably apply to functions
-- created later in the same CREATE EXTENSION transaction, so new functions default
-- to GRANT EXECUTE TO PUBLIC. Re-REVOKE explicitly so the Ring-1 primitives carry no
-- PUBLIC EXECUTE; ck_substrate (their owner) keeps it.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
