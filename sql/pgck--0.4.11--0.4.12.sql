-- ============================================================================
-- pgck 0.4.11 -> 0.4.12 — v0.5 roadmap T5: full SHACL ValidationReport
-- ============================================================================
-- `instance.validate` (ckp.validate_instance, v0.4.3) shipped a required-props
-- (`sh:minCount≥1`) gate returning {conforms, missing_required[]}. T5 surfaces pgRDF's
-- full W3C SHACL Core report — typed violations (datatype, cardinality, node-kind,
-- pattern) — via `pgrdf.validate(data, shapes, mode => 'native')` (pgRDF advisory §2;
-- NOT mode=>'sparql', which is upstream-gated, ERRATA E-012).
--
-- The candidate body is projected to RDF (ckp._body_to_ttl) into a scratch graph and
-- validated against the project kernel graph's shapes. The seal keeps its required-props
-- gate (unchanged, low-risk), so validate is the STRICTER superset:
--   **validate-conforms ⟹ seal-accepts** (validate additionally flags datatype/pattern/
--   nodeKind violations the seal does not yet enforce). An unshaped type has no targetClass
--   match → conforms:true (valid silence, as before).
--
-- Exit test: sql/test/s46_validation_report.sql — a Ship with crew_size:xsd:integer:
-- missing crew_size → cardinality (minCount) violation; crew_size:"twelve" → datatype
-- violation; a valid Ship conforms AND seals (the ⟹ direction).
-- ============================================================================

-- ---- ckp._body_to_ttl — generic instance body → RDF (for validation) ----------
CREATE OR REPLACE FUNCTION ckp._body_to_ttl(p_body jsonb, p_subj text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $b2t$
DECLARE
  v_type text := p_body->>'type';
  v_ttl  text;
  v_key  text;
  v_val  jsonb;
  v_obj  text;
  s      text;
BEGIN
  v_ttl := '<'||p_subj||'> a <'||COALESCE(v_type, 'urn:ckp:Unknown')||'> .'||chr(10);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_body)
  LOOP
    -- control keys + non-IRI keys are not RDF properties.
    CONTINUE WHEN v_key IN ('type','@id','participant','participant_display_name','participant_email');
    CONTINUE WHEN position(':' in v_key) = 0;
    IF    jsonb_typeof(v_val) = 'number'  THEN v_obj := v_val::text;            -- xsd:integer / decimal
    ELSIF jsonb_typeof(v_val) = 'boolean' THEN v_obj := v_val::text;            -- xsd:boolean
    ELSIF jsonb_typeof(v_val) = 'string'  THEN
      s := v_val #>> '{}';
      IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' THEN
        v_obj := '<'||s||'>';                                                   -- IRI node (nodeKind sh:IRI)
      ELSE
        v_obj := '"'||replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'"';  -- xsd:string literal
      END IF;
    ELSE
      CONTINUE;                                                                 -- arrays/objects: not simple values
    END IF;
    v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> '||v_obj||' .'||chr(10);
  END LOOP;
  RETURN v_ttl;
END;
$b2t$;
ALTER FUNCTION ckp._body_to_ttl(jsonb, text) OWNER TO ck_substrate;

-- ---- ckp.validate_instance — full native SHACL ValidationReport ---------------
CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $vi$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);
  v_type    text := v_body->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_subj    text := 'urn:ckp:validate:'||pg_backend_pid();
  v_ns      text;
  v_propmap jsonb;
  v_resolved jsonb;
  v_key text; v_val jsonb; v_kiri text;
  v_scratch bigint;
  v_kernel  bigint;
  v_ttl     text;
  v_report  jsonb;
BEGIN
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;

  -- Resolve the body's short keys to declared property IRIs (mirror ckp.create_typed) so validate
  -- accepts the same {type, …fields} shape as instance.create. Already-IRI keys pass through.
  v_ns := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;
  SELECT COALESCE(jsonb_object_agg(regexp_replace(path, '^.*[/#]', ''), path), '{}'::jsonb)
    INTO v_propmap
  FROM (
    SELECT DISTINCT j->>'path' AS path
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?path WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
        ?s sh:targetClass <%s> ; sh:property ?p . ?p sh:path ?path } }
    $q$, v_proj, v_type)) AS j WHERE j->>'path' IS NOT NULL
  ) p;
  v_resolved := jsonb_build_object('type', v_type);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_body) LOOP
    CONTINUE WHEN v_key IN ('type', '@id', 'sub');
    IF position(':' in v_key) > 0 THEN v_kiri := v_key;
    ELSIF v_propmap ? v_key THEN v_kiri := v_propmap->>v_key;
    ELSE v_kiri := v_ns || v_key; END IF;
    v_resolved := v_resolved || jsonb_build_object(v_kiri, v_val);
  END LOOP;

  -- project the resolved candidate body to RDF in a scratch graph.
  v_ttl := ckp._body_to_ttl(v_resolved, v_subj);
  v_scratch := pgrdf.add_graph('urn:ckp:validate:'||pg_backend_pid());
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    PERFORM pgrdf.parse_turtle(v_ttl, v_scratch, 'urn:ckp:validate#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'detail', SQLERRM);
  END;

  -- full native W3C SHACL Core report against the kernel shapes.
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', v_proj));
  v_report := pgrdf.validate(v_scratch, v_kernel, 'native');
  PERFORM pgrdf.clear_graph(v_scratch);

  RETURN jsonb_build_object('ok', true, 'type', v_type,
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb),
    'report',     v_report);
END;
$vi$;
ALTER FUNCTION ckp.validate_instance(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.validate_instance(jsonb) IS
  'T5 (v0.4.12): instance.validate — projects the candidate body to RDF (ckp._body_to_ttl) and runs '
  'pgrdf.validate(…, mode=>''native'') for the full W3C SHACL Core report (typed violations). The stricter '
  'superset of the seal''s required-props gate: validate-conforms ⟹ seal-accepts. Unshaped type → conforms.';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
