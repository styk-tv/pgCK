-- pgck 0.4.20 -> 0.4.21 — create_typed: file v3.7 CORE lifecycle keys under the core NS.
--
-- Bug (found via oci-germination#11 / ck-allinone v0.7.27, root of the week-long "invalid_transition
-- after set_transition_map"): create_typed's body-assembly loop files any undeclared bare key under
-- the TYPE's namespace (v_keyiri := v_ns || v_key). So instance.create {type, lifecycle_state:'pending'}
-- stored the state as <type-ns>lifecycle_state, while ckp.transition's gate and task.create read/write
-- it under the v3.7 core NS https://conceptkernel.org/ontology/v3.7/lifecycle_state. The requested
-- initial state landed where nothing reads it → the instance was silently treated as 'planned' → a
-- pending→sealed map then (correctly) denied planned→sealed. NOT a project mismatch (#6/#7 verified
-- working end to end); a namespace mis-filing of core keys.
--
-- Fix: recognize the v3.7 CORE lifecycle keys and file them under the core NS N — matching
-- task.create and the transition gate — BEFORE the type-NS fallback, AFTER the declared-property
-- check (so a type that DECLARES its own lifecycle_state property is unaffected: v_propmap wins).
-- Same "never silently mislead" principle as #6/#7: the state now lands where readers expect it.
-- Combo with cklib: the client sends these as bare keys (it does) and reads them under the core NS.

CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ct$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_sub     text := p_payload->>'sub';
  N         text := 'https://conceptkernel.org/ontology/v3.7/';       -- v3.7 core NS (gate + task.create)
  v_core    text[] := ARRAY['lifecycle_state'];                       -- recognized core keys → core NS
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

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

  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_payload)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id');                    -- control keys, not data
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                             -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                                 -- declared localname -> its path IRI
    ELSIF v_key = ANY(v_core) THEN
      v_keyiri := N || v_key;                                        -- v3.7 core key -> core NS (gate + task.create)
    ELSE
      v_keyiri := v_ns || v_key;                                     -- other undeclared -> under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);         -- `->` value: preserves number/bool/object types
  END LOOP;

  v_body := v_body || jsonb_build_object(
    'https://conceptkernel.org/ontology/v3.7/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    v_body := v_body || jsonb_build_object('participant', jsonb_build_object('sub', v_sub));
  END IF;

  PERFORM ckp.seal(v_iid, v_body);

  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$ct$;
ALTER FUNCTION ckp.create_typed(jsonb) OWNER TO ck_substrate;
