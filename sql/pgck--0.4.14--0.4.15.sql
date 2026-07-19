-- ============================================================================
-- pgck 0.4.14 -> 0.4.15 — STABILIZATION: provenance id-form symmetry
-- ============================================================================
-- v0.4.14 made `reach`/`link` id-form-flexible via `ckp._resolve_ref` (bare id ->
-- stamped @id, the IRI direction). But `instance.provenance` keys body/proof/ledger/
-- verify by the RAW payload id against the BARE id columns (ckp.instances.id,
-- ckp.proof.about, ckp.ledger.instance_id), and calls no resolver — so a client
-- passing the @id / full-IRI (the form reach/link now accept, and the form a downstream consumer
-- addresses by) matches nothing and gets a HOLLOW `ok:true` with null body/proof.
-- Third-party confirmed (oci-germination relay of the downstream-consumer D1 repro on 0.4.14).
--
-- `ckp._resolve_id` is the INVERSE of `_resolve_ref` (bare-or-IRI -> bare id), and the
-- provenance branch (sql/dispatch.sql) routes its `tid` through it — so a bare id AND
-- its @id resolve to the same provenance envelope, symmetric with reach/link/get.
-- A bare id that exists resolves to itself, so existing bare-id callers are unchanged;
-- an unresolvable ref returns as-is (provenance stays hollow, never a false positive).
--
-- (Also bundles the forward-only `pgck_version()` de-stale already on main — cd9920a.)
--
-- Exit test: s51_provenance_id_form — provenance(bare) ≡ provenance(@id).
-- ============================================================================

-- ---- ckp._resolve_id — the inverse of _resolve_ref: bare-or-IRI -> bare instance id ----
CREATE OR REPLACE FUNCTION ckp._resolve_id(p_ref text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ri$
DECLARE v_id text;
BEGIN
  IF p_ref IS NULL OR btrim(p_ref) = '' THEN RETURN NULL; END IF;
  -- a bare id that exists resolves to itself (the common path — bare-id callers unchanged).
  IF EXISTS (SELECT 1 FROM ckp.instances WHERE id = p_ref) THEN RETURN p_ref; END IF;
  -- a stamped @id (the form create returns + reach/link accept) -> that instance's bare id.
  SELECT id INTO v_id FROM ckp.instances WHERE body->>'@id' = p_ref LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  -- the deterministic urn:ckp:instance:<id> fallback _resolve_ref mints -> <id> if real.
  IF p_ref LIKE 'urn:ckp:instance:%' THEN
    v_id := substring(p_ref from '^urn:ckp:instance:(.*)$');
    IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM ckp.instances WHERE id = v_id) THEN RETURN v_id; END IF;
  END IF;
  -- no match: return as-is (provenance stays hollow, exactly as today — never a false positive).
  RETURN p_ref;
END;
$ri$;
ALTER FUNCTION ckp._resolve_id(text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp._resolve_id(text) IS
  'v0.4.15: the inverse of ckp._resolve_ref — resolve a bare-or-IRI reference to the BARE instance id that '
  'the id-keyed tables use. Routed through by the provenance branch so provenance(bare) and provenance(@id) '
  'return the same envelope (id-form symmetry, matching reach/link/get). Identity on existing bare ids.';

-- NOTE: the `instance.provenance` branch in sql/dispatch.sql now reads
--   DECLARE tid text := ckp._resolve_id(p_payload->>'id');
-- so the @id / full-IRI form resolves to its bare id before the id-keyed lookups. dispatch.sql is the
-- fresh-install source of ckp.dispatch (loaded earlier in the include chain); its plpgsql body references
-- ckp._resolve_id, which this file defines — both present by the time dispatch is called at runtime.

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
