-- ============================================================================
-- pgck 0.4.7 -> 0.4.8 — v0.5 roadmap T1: instance.query derived QueryShape
-- ============================================================================
-- Until now `ckp.query` validated filter keys by a generic regex, not against the
-- kernel's DECLARED properties — the §6.1 concretion. T1 makes the kernel's own shape
-- the QueryShape: a shaped type's permissible filter keys are its declared
-- `sh:property`/`sh:path` set (read from urn:ckp:<project>/kernel/ck, the same graph
-- `ckp.seal`/`ckp.create_typed` read), and a short filter key is resolved to its
-- declared property IRI before the WHERE is built — which also fixes querying typed
-- instances whose bodies store full-IRI keys.
--
-- Back-compat: an UNSHAPED type (no declared properties in the kernel graph) keeps the
-- prior regex key gate — so existing untyped reads (e.g. the s29 `urn:test:E` fixture)
-- are unchanged, and "unshaped = permissive" mirrors validate_instance's valid-silence.
--
-- Execution is unchanged: a parameter-safe WHERE over `ckp.instances` (the jsonb
-- instance store), closed operator enum, bounded limit/offset, no caller expression
-- position. (instance.query reads the instance TABLE, not pgRDF graphs — so the
-- pgRDF join-pin advisory applies to T7's compiled graph reads / reach, not here; the
-- only pgRDF call here is the single-pattern shape read.)
--
-- Exit test: sql/test/s42_query_shape.sql — a Ship with declared crew_size:int + name;
-- query crew_size>=10 returns the matching ships; an undeclared filter key is rejected;
-- the unshaped fixture still queries by short key.
-- ============================================================================

CREATE OR REPLACE FUNCTION ckp.query(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $query$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_ops     jsonb := '{"eq":"=","neq":"<>","lt":"<","lte":"<=","gt":">","gte":">=","contains":"LIKE"}'::jsonb;
  v_key_re  text := '^[A-Za-z][A-Za-z0-9:#/._-]*$';   -- the unshaped-fallback key gate
  v_propmap jsonb;          -- declared localname -> full path IRI ({} when the type is unshaped)
  v_shaped  boolean;
  v_where   text;
  v_limit   int := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 100), 1), 1000);
  v_offset  int := GREATEST(COALESCE((p_payload->>'offset')::int, 0), 0);
  f         jsonb;
  v_op text; v_key_in text; v_key text; v_val text;
  v_sql text; v_result jsonb;
BEGIN
  IF v_type IS NULL OR v_type !~ '^[A-Za-z]' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type', 'type', v_type);
  END IF;

  -- Derive the type's declared property map from the kernel graph (same read as create_typed).
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

  v_where := format('(body->>%L) = %L', 'type', v_type);   -- base: this instance type only

  FOR f IN SELECT jsonb_array_elements(COALESCE(p_payload->'filter', '[]'::jsonb)) LOOP
    v_op := f->>'op'; v_key_in := f->>'key'; v_val := f->>'value';
    IF NOT (v_ops ? v_op) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_operator', 'op', v_op,
                                'allowed', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_ops) k));
    END IF;

    -- KEY RESOLUTION — the T1 change.
    IF v_shaped THEN
      -- shaped type: the key MUST be a declared property (by localname or full IRI).
      IF v_propmap ? v_key_in THEN
        v_key := v_propmap->>v_key_in;                                   -- declared localname -> IRI
      ELSIF v_key_in IS NOT NULL
            AND EXISTS (SELECT 1 FROM jsonb_each_text(v_propmap) e WHERE e.value = v_key_in) THEN
        v_key := v_key_in;                                              -- already a declared full IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_filter_key',
                                  'key', v_key_in, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      -- unshaped type: the prior regex gate (permissive back-compat).
      IF v_key_in IS NULL OR v_key_in !~ v_key_re THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'key', v_key_in);
      END IF;
      v_key := v_key_in;
    END IF;

    -- WHERE construction (unchanged operator logic; quote_literal values + enum operators).
    IF v_op = 'contains' THEN
      v_where := v_where || format(' AND (body->>%L) LIKE %L', v_key, '%'||COALESCE(v_val,'')||'%');
    ELSIF v_op IN ('lt','lte','gt','gte') THEN
      IF v_val IS NULL OR v_val !~ '^-?[0-9.]+$' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_numeric_value', 'op', v_op, 'value', v_val);
      END IF;
      v_where := v_where || format(' AND (body->>%L) ~ ''^-?[0-9.]+$'' AND (body->>%L)::numeric %s %s',
                                   v_key, v_key, v_ops->>v_op, v_val);
    ELSE  -- eq, neq
      v_where := v_where || format(' AND (body->>%L) %s %L', v_key, v_ops->>v_op, v_val);
    END IF;
  END LOOP;

  v_sql := format(
    'SELECT jsonb_agg(jsonb_build_object(''id'', id, ''body'', body) ORDER BY id) '
    'FROM (SELECT id, body FROM ckp.instances WHERE %s ORDER BY id LIMIT %s OFFSET %s) t',
    v_where, v_limit, v_offset);
  EXECUTE v_sql INTO v_result;
  RETURN jsonb_build_object('ok', true, 'type', v_type, 'shaped', v_shaped,
                            'count', COALESCE(jsonb_array_length(v_result), 0),
                            'rows', COALESCE(v_result, '[]'::jsonb));
END;
$query$;
ALTER FUNCTION ckp.query(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.query(jsonb) IS
  'T1 (v0.4.8): instance.query — the derived QueryShape. A shaped type''s filter keys MUST be its '
  'declared sh:property set (short key resolved to the declared IRI; undeclared rejected); an unshaped '
  'type keeps the regex key gate. Closed operator enum, bounded limit/offset, parameter-safe WHERE over '
  'ckp.instances. No caller expression position.';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
