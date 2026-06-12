-- ============================================================================
-- pgck 0.4.10 -> 0.4.11 — v0.5 roadmap T4: generic per-declared-shape update patch
-- ============================================================================
-- `instance.update` was a Task-shaped closed allow-list (`task.update`) — the §4
-- concretion. T4 adds the generic write-side mirror of `ckp.create_typed`:
-- `instance.update {id, patch:{…}}` patches an instance by the type's DECLARED
-- properties, re-sealed through the gate (which re-validates the required props).
--
-- Routing (sql/dispatch.sql): `instance.update` with a `patch` sub-object → the generic
-- path; the legacy flat `{id, …fields}` form still routes to `task.update` (back-compat).
--
-- Exit test: sql/test/s45_update_patch.sql — create a Ship crew_size:12; patch crew_size→20
-- (number preserved, proof chain intact, re-verified); patching an undeclared field rejected.
-- ============================================================================

CREATE OR REPLACE FUNCTION ckp.update_typed(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ut$
DECLARE
  v_id      text := p_payload->>'id';
  v_patch   jsonb := p_payload->'patch';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_cur     jsonb;
  v_type    text;
  v_ns      text;
  v_propmap jsonb;
  v_shaped  boolean;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_id IS NULL OR btrim(v_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_required'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id); END IF;

  v_type := v_cur->>'type';
  v_ns   := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;

  -- declared property map for the instance's type (same read as create_typed).
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
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_cur := v_cur - 'participant';   -- re-resolved by ckp.seal from any supplied claims

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    CONTINUE WHEN v_key IN ('id', 'type', '@id');   -- not patchable via this path
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                    -- already a full IRI
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
    END IF;
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$ut$;
ALTER FUNCTION ckp.update_typed(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.update_typed(jsonb) IS
  'T4 (v0.4.11): generic instance.update — patch {id, patch:{…}} keyed by the type''s DECLARED '
  'properties (short key -> declared IRI; undeclared rejected for a shaped type), merged + re-sealed '
  '(gate re-validates required props). The write-side mirror of ckp.create_typed.';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
