-- ============================================================================
-- pgck 0.4.3 -> 0.4.4 — Tier 2 (1/3): GENERIC TYPED instance.create
-- ============================================================================
-- The adoption keystone (oci-germination's NOTIFY + CK.Lib.Js wire-contract Q2).
--
-- Before this file, `instance.create` was a Task/Goal CONCRETION: it routed by
-- payload key (`{task:…}` -> task.create, `{name:…}` -> kernel.create) and knew
-- only those two shapes. A non-Task type could not be created through the door.
--
-- `ckp.create_typed(payload)` is the §4 generic path: a uniform
--   { "type": "<full class IRI>", "<field>": <value>, … }
-- body is routed by `type` against the kernel's OWN sealed shape. It maps each
-- caller field to the type's declared property IRIs (read from the kernel graph's
-- SHACL `sh:property`/`sh:path`), assembles the instance body, and seals it.
--
-- The required-props gate is NOT re-implemented here: `ckp.seal` already validates
-- the assembled body against `urn:ckp:<project>/kernel/ck`
-- (`sh:targetClass <type> ; sh:property [ sh:path ?p ; sh:minCount ?n>=1 ]`).
-- So `create_typed` is body-assembly + a call to the existing seal floor — the
-- gate that makes the type real comes for free, and matches `validate_instance`
-- exactly (validate ⟺ seal) for any declared type, not just Task/Goal.
--
-- Routing is added in sql/dispatch.sql: when `instance.create` carries a `type`
-- and NEITHER a `task` nor a `name` sub-object, the dispatch sends it here; the
-- legacy `{task}`/`{name}` payload-key forms still route to task.create/kernel.create
-- (back-compat during the alias window — see CK.Lib.Js wire-contract RESPONSE Q2).
--
-- Exit test: sql/test/s38_generic_typed_create.sql — declare a Ship NodeShape with a
-- required `crew_size`, create a Ship WITH it (seals) and WITHOUT it (rejected by the
-- gate). An ADOPTER modelling a non-Task type, not this suite's own fixtures.
-- ============================================================================

-- ---- ckp.create_typed — the generic §4 typed create -------------------------
CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ct$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_sub     text := p_payload->>'sub';
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;          -- declared localname -> full path IRI (for this type)
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;
  -- `type` MUST be the full class IRI the kernel shape declares as sh:targetClass.
  -- A bare local name can never match a targetClass IRI, so the required-props gate
  -- would silently pass (vacuous) and the "typed" claim would be a lie. Reject it
  -- with a hint instead of sealing an ungated instance.
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');                 -- after last / or #
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');                 -- namespace incl. trailing / or #
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- Declared property map for this type: localname -> full path IRI, read from the
  -- kernel's OWN sealed shape in the project kernel graph (same graph ckp.seal gates on).
  SELECT COALESCE(jsonb_object_agg(regexp_replace(path, '^.*[/#]', ''), path), '{}'::jsonb)
    INTO v_propmap
  FROM (
    SELECT DISTINCT j->>'path' AS path
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?path WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
        ?s sh:targetClass <%s> ; sh:property ?p . ?p sh:path ?path } }
    $q$, v_proj, v_type)) AS j
    WHERE j->>'path' IS NOT NULL
  ) p;

  -- Assemble the body: type + @id, then each caller field mapped to a property IRI.
  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_payload)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id');                  -- control keys, not data
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                            -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                               -- declared localname -> its path IRI
    ELSE
      v_keyiri := v_ns || v_key;                                    -- undeclared: namespace under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);        -- `->` value: preserves number/bool/object types
  END LOOP;

  -- created_at + optional participant identity (same convention as task.create).
  v_body := v_body || jsonb_build_object(
    'https://conceptkernel.org/ontology/v3.7/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    v_body := v_body || jsonb_build_object('participant', jsonb_build_object('sub', v_sub));
  END IF;

  -- Seal: required-props gate against urn:ckp:<project>/kernel/ck runs inside here.
  -- A body missing a declared sh:minCount>=1 property RAISEs and is caught below.
  PERFORM ckp.seal(v_iid, v_body);

  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$ct$;
ALTER FUNCTION ckp.create_typed(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.create_typed(jsonb) IS
  'Tier 2 §4 generic typed instance.create: route a uniform {type:<class IRI>, …fields} body by type against the kernel''s declared SHACL shape; assemble the instance body (fields -> declared property IRIs) and seal. The required-props gate is ckp.seal''s, against urn:ckp:<project>/kernel/ck — so validate ⟺ seal holds for any declared type, not just Task/Goal.';

-- ---- closing floor pass (mirror of every prior upgrade file) -----------------
-- create_typed is defined above; re-assert the schema floor so the new function is
-- owned by ck_substrate and unreachable except through the dispatch door.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
