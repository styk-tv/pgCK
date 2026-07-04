-- pgck 0.4.17 -> 0.4.18 — ckp.query filter-key resolution hardening (pgCK#6).
--
-- Bug: a property-path filtered `query` returned `[]` while the unfiltered query returned the
-- instances. Root cause: the filter is plain SQL (`body->>key`) over ckp.instances; the only
-- pgRDF touch is the SHACL property-map read that resolves the key's localname -> full IRI. When
-- that read is empty for the session's project (type resolves `shaped:false`), the OLD code fell
-- back to the RAW localname (`name`), but instance bodies key properties by full IRI
-- (`urn:ckp:kernel#name`) -> `body->>'name'` matched nothing -> silent `[]`.
--
-- Fix (pgCK#6): in the unshaped fallback, resolve the filter key against the ACTUAL instance-body
-- keys (exact full-IRI OR by localname suffix) — jsonb-only, project-independent, so the filter
-- runs against the key the bodies actually use. And NEVER a silent `[]`: a key that maps to no
-- stored property returns a typed `unresolved_shape` (mirrors the existing `undeclared_filter_key`
-- grammar). The shaped path (declared-property gate) is unchanged; bare-key bodies still resolve
-- to themselves, so back-compat (s29) holds.

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

    -- KEY RESOLUTION.
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
      -- unshaped for THIS session's project (the shape isn't in urn:ckp:<project>/kernel/ck, or
      -- the type is genuinely unshaped). Resolve the key against the ACTUAL instance-body keys —
      -- exact full-IRI OR by localname suffix — so the filter runs against the key the bodies use,
      -- independent of the shape/project read (pgCK#6). Bare-key bodies (localname == key) resolve
      -- to themselves, so s29 back-compat holds.
      IF v_key_in IS NULL OR v_key_in !~ v_key_re THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'key', v_key_in);
      END IF;
      SELECT bk INTO v_key
      FROM ckp.instances i
      CROSS JOIN LATERAL jsonb_object_keys(i.body) AS bk
      WHERE i.body->>'type' = v_type
        AND (bk = v_key_in OR regexp_replace(bk, '^.*[/#]', '') = v_key_in)
      LIMIT 1;
      IF v_key IS NULL THEN
        -- NEVER a silent [] (pgCK#6): the key maps to no stored property on this type.
        IF EXISTS (SELECT 1 FROM ckp.instances WHERE body->>'type' = v_type) THEN
          RETURN jsonb_build_object('ok', false, 'error', 'unresolved_shape',
                                    'key', v_key_in, 'type', v_type,
                                    'hint', 'no shape for this type in the session project and no instance carries this property key');
        END IF;
        v_key := v_key_in;   -- no instances of this type: the filtered read is legitimately empty
      END IF;
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
