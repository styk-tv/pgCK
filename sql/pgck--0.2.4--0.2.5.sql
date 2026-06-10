-- pgck 0.2.4 -> 0.2.5 — CI-A-2: the locked dispatch door (CKP v3.9 §7/§2, Phase A).
-- SPEC.ROADMAP.v3.9.CHECKLIST index 22. Depends on CI-A-4 (roles/floor) + CI-A-3.
--
-- v3.9 §7 makes ckp.dispatch the ONE function a connection ever holds. This migration
-- establishes the four-tuple door ⟨verb, kernel_urn, payload, identity⟩ as a SECURITY
-- DEFINER function OWNED BY ck_substrate, GRANTed to ck_participant and NOTHING else.
--
-- Scope note (honest): the v3.9 §2.2 dispatch ORDER (sealed-registry lookup, epoch
-- check, role/grant, ValidationReport shape gate, plane route) is built across CI-B
-- (registry), CI-C (epoch), CI-D (governance plane). CI-A-2 ships the DOOR — locked,
-- owned, granted — with a minimal transitional read body so Track A's "exactly one
-- capability" is demonstrable end-to-end now. The legacy 2-arg ckp.dispatch(text,jsonb)
-- in sql/dispatch.sql is deliberately NOT baked into the extension; CI-B makes the
-- four-tuple the canonical, registry-backed ingress.
--
-- Idempotent. Test: sql/test/s13_ci_a2_dispatch_only.sql.

-- ============================================================================
-- §1. The four-tuple door — SECURITY DEFINER, owner ck_substrate.
-- ============================================================================
CREATE OR REPLACE FUNCTION ckp.dispatch(
  p_verb       text,   -- exact-match key into the sealed registry (CI-B)
  p_kernel_urn text,   -- ckp://Kernel#<Name>:<Version>
  p_payload    jsonb,  -- validated against the affordance inShape BEFORE use (CI-B-3)
  p_identity   text    -- derived ONLY from the verified JWT (TR-02); never caller-asserted
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $disp$
DECLARE
  res jsonb;
BEGIN
  -- Transitional minimal surface (CI-A-2). The full §2.2 fail-fast order lands in
  -- CI-B/CI-C/CI-D; here we prove the locked door is usable as definer.
  CASE p_verb
    WHEN 'instances.count' THEN
      res := jsonb_build_object('ok', true, 'count', (SELECT count(*) FROM ckp.instances));
    WHEN 'instance.verify' THEN
      res := jsonb_build_object('ok', true, 'id', p_payload->>'id',
                                'verified', ckp.verify(p_payload->>'id'));
    ELSE
      -- unknown verb -> the delegation seam (becomes a sealed-delegation fact in CI-B-4).
      res := jsonb_build_object('ok', false, 'delegate', true,
                                'error', 'verb not governed yet (CI-B): ' || p_verb);
  END CASE;
  RETURN res || jsonb_build_object('kernel', p_kernel_urn);
END;
$disp$;

ALTER FUNCTION ckp.dispatch(text, text, jsonb, text) OWNER TO ck_substrate;

-- Floor every ckp function from PUBLIC explicitly (ADP is unreliable inside CREATE
-- EXTENSION, so newly-created functions — incl. this dispatch — default to PUBLIC
-- EXECUTE). This re-revokes ALL ckp functions, then re-grants ck_substrate.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- The single capability a connection/agent receives — and nothing else.
GRANT EXECUTE ON FUNCTION ckp.dispatch(text, text, jsonb, text) TO ck_participant;

COMMENT ON FUNCTION ckp.dispatch(text, text, jsonb, text) IS
  'CKP v3.9 §2 the closed dispatch door: <verb, kernel_urn, payload, identity>. '
  'SECURITY DEFINER as ck_substrate; the ONLY function granted to ck_participant '
  '(CI-A-2). Registry/typed-dispatch behavior fills in across CI-B/CI-C/CI-D.';

-- ============================================================================
-- §2. Operator-forensics view — DEFERRED (and why).
-- ============================================================================
-- v3.9 §7 allows an OPTIONAL read-only operator-forensics VIEW (operator surface,
-- never granted to ck_participant). It is intentionally NOT created here: a VIEW
-- resolves its base tables at CREATE-time, but ckp.instances/ledger/proof are minted
-- at RUNTIME by ckp.bootstrap_kernel(), not at CREATE EXTENSION — so a top-level
-- CREATE VIEW over them fails the install. Adding the view belongs with the bootstrap
-- (or a later operator-role story). The CI-A-2 door + grant above is the substance;
-- the "operator view (if added)" clause is satisfied by not adding one — a
-- participant's surface stays exactly { ckp.dispatch } and nothing else.
