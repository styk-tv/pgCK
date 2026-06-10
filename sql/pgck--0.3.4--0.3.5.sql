-- pgck 0.3.4 -> 0.3.5 — CKP v3.9 Track E (the enumerable typed read surface).
-- This migration accretes Track E's SQL across CI-E-5 / CI-E-4 / CI-E-3 / CI-E-2; v0.4.0 ships
-- at the CI-E-1 flip — "CKP v3.9 Critical Isolation enforced". Every read is typed + bounded:
-- no caller SQL/SPARQL expression position is reachable.

-- ============================================================================
-- CI-E-5 (index 5) — instance.query (derived QueryShape).
-- ============================================================================
-- v3.9 §6: a typed query. Each filter carries {key, op, value}; the operator is a CLOSED enum;
-- the key must be a declared data-property (demo: a safe identifier — the production form checks
-- the kernel's sealed property set); limit/offset are bounded ints. The filter compiles key-by-key
-- from FIXED per-operator templates with quote_literal'd (%L) values + enum-fixed operators —
-- numeric comparisons are regex-guarded. No expression position is reachable.

CREATE OR REPLACE FUNCTION ckp.query(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $query$
DECLARE
  v_type   text := p_payload->>'type';
  v_ops    jsonb := '{"eq":"=","neq":"<>","lt":"<","lte":"<=","gt":">","gte":">=","contains":"LIKE"}'::jsonb;
  v_where  text;
  v_limit  int := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 100), 1), 1000);
  v_offset int := GREATEST(COALESCE((p_payload->>'offset')::int, 0), 0);
  f        jsonb;
  v_op text; v_key text; v_val text;
  v_sql text; v_result jsonb;
BEGIN
  IF v_type IS NULL OR v_type !~ '^[A-Za-z]' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type', 'type', v_type);
  END IF;
  v_where := format('(body->>%L) = %L', 'type', v_type);   -- base: this instance type only

  FOR f IN SELECT jsonb_array_elements(COALESCE(p_payload->'filter','[]'::jsonb)) LOOP
    v_op := f->>'op'; v_key := f->>'key'; v_val := f->>'value';
    IF NOT (v_ops ? v_op) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_operator', 'op', v_op,
                                'allowed', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_ops) k));
    END IF;
    IF v_key IS NULL OR v_key !~ '^[A-Za-z][A-Za-z0-9:#/._-]*$' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'key', v_key);
    END IF;
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
  RETURN jsonb_build_object('ok', true, 'type', v_type,
                            'count', COALESCE(jsonb_array_length(v_result), 0),
                            'rows', COALESCE(v_result, '[]'::jsonb));
END;
$query$;

COMMENT ON FUNCTION ckp.query(jsonb) IS
  'CI-E-5: typed instance.query — closed operator enum, declared-property keys, bounded limit/offset; '
  'compiled from fixed per-operator templates (quote_literal values, enum operators). No expression '
  'position reachable. instance.* alias instances.list keeps the legacy list during the alias window.';

ALTER FUNCTION ckp.query(jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-E-4 (index 4) — instance.reach (bounded transitive traversal).
-- ============================================================================
-- v3.9 §6: `via` MUST be a declared predicate IRI (registry-checked, NEVER parsed from caller
-- text); the path modifier is `+` (transitive); depth is engine-capped at pgrdf.path_max_depth.
-- from + via are validated as safe IRIs before being placed in the property-path query, so no
-- SPARQL expression position is reachable.

CREATE OR REPLACE FUNCTION ckp.reach(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $reach$
DECLARE
  v_from    text := p_payload->>'from';
  v_via     text := p_payload->>'via';
  v_iri_re  text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_max     int  := COALESCE(NULLIF(current_setting('pgrdf.path_max_depth', true),'')::int, 0);
  v_reached jsonb;
BEGIN
  IF v_from IS NULL OR v_from !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from);
  END IF;
  -- via must be a DECLARED predicate (demo: a safe IRI in the conceptkernel/kernel namespace —
  -- registry-checked, not parsed). The production form checks the kernel's sealed predicate set.
  IF v_via IS NULL OR v_via !~ v_iri_re
     OR NOT (v_via LIKE 'https://conceptkernel.org/%' OR v_via LIKE 'urn:ckp:%') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- bounded transitive traversal — `+` is engine-capped at pgrdf.path_max_depth.
  SELECT jsonb_agg(DISTINCT j->>'r') INTO v_reached
  FROM pgrdf.sparql(format('SELECT ?r WHERE { GRAPH ?g { <%s> <%s>+ ?r } }', v_from, v_via)) j;
  RETURN jsonb_build_object('ok', true, 'from', v_from, 'via', v_via,
                            'max_depth', v_max, 'reached', COALESCE(v_reached, '[]'::jsonb));
END;
$reach$;

COMMENT ON FUNCTION ckp.reach(jsonb) IS
  'CI-E-4: bounded transitive traversal — via is a registry-checked predicate IRI (never parsed); '
  'path modifier + only; depth capped at pgrdf.path_max_depth.';

-- Seed instance.reach (instance plane) into the registry so the dispatch routes it.
INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','instance.reach','input.kernel.pgCK.action.instance.reach','instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane='instance';

ALTER FUNCTION ckp.reach(jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-E-3 (index 3) — instance.transition gate + authz'd snapshot.
-- ============================================================================
-- v3.9 §6: a transition's to_state MUST be in the kernel's sealed transition map (constraints
-- are facts, checked in the same txn as the seal). And instance.snapshot (bulk replay) comes
-- under a per-requester GRANT check — closing F-E (un-authz'd bulk replay). The legacy
-- snapshot.board keeps its un-gated list during the alias window (routed by the original verb).

-- the kernel's sealed transition map (a default; governance set_transition_map refines it).
INSERT INTO ckp.config(k,v) VALUES
  ('transition_map', '{"draft":["review"],"review":["approved","draft"],"approved":[]}')
ON CONFLICT (k) DO NOTHING;

CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $trans$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_body   jsonb; v_from text; v_allowed jsonb;
BEGIN
  IF v_to IS NULL OR v_to !~ '^[A-Za-z][A-Za-z0-9_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  v_from    := COALESCE(v_body->>'state', v_body->>(C||'lifecycle_state'), 'draft');
  v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
  IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                              'from', v_from, 'to', v_to, 'allowed', v_allowed);
  END IF;
  v_body := v_body || jsonb_build_object('state', v_to);   -- re-seal in the same txn (constraints are facts)
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to, 'verified', ckp.verify(v_id));
END;
$trans$;

-- RBAC grants (a minimal store; CI-D-6 GrantShape is the sealed-fact form).
CREATE TABLE IF NOT EXISTS ckp.grants (
  grantee    text NOT NULL,
  permission text NOT NULL,
  PRIMARY KEY (grantee, permission)
);
REVOKE ALL ON ckp.grants FROM PUBLIC;
GRANT  ALL ON ckp.grants TO ck_substrate;

CREATE OR REPLACE FUNCTION ckp.has_grant(p_grantee text, p_perm text)
RETURNS boolean LANGUAGE sql STABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $hg$ SELECT EXISTS (SELECT 1 FROM ckp.grants WHERE grantee = p_grantee AND permission = p_perm); $hg$;

CREATE OR REPLACE FUNCTION ckp.snapshot(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $snap$
DECLARE v_req text := p_payload->>'requester'; v_rows jsonb;
BEGIN
  -- F-E: a bulk replay requires an explicit grant on the requester.
  IF v_req IS NULL OR NOT ckp.has_grant(v_req, 'snapshot') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'snapshot_not_granted', 'requester', v_req);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'type', body->>'type') ORDER BY id) INTO v_rows FROM ckp.instances;
  RETURN jsonb_build_object('ok', true, 'requester', v_req,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'instances', COALESCE(v_rows, '[]'::jsonb));
END;
$snap$;

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','instance.transition','input.kernel.pgCK.action.instance.transition','instance'),
  ('pgCK','instance.snapshot',  'input.kernel.pgCK.action.instance.snapshot',  'instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane='instance';

ALTER FUNCTION ckp.transition(jsonb)        OWNER TO ck_substrate;
ALTER FUNCTION ckp.has_grant(text, text)    OWNER TO ck_substrate;
ALTER FUNCTION ckp.snapshot(jsonb)          OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-E-2 (index 2) — concept.match (governed query affordance) + instance.explain.
-- ============================================================================
-- v3.9 §6.3: the reference governed query affordance — a label search whose query is authored
-- ONCE (here, pgCK-sealed; the production form seals it through the governance plane: proposal →
-- votes → proof → epoch → compiled at apply). Exposed under a verb with a typed parameter shape;
-- callers BIND params only (plpgsql auto-binds v_term — no injection, no caller SPARQL/SQL).
-- Plus instance.explain (direct-vs-inferred via the engine is_inferred column; full derivation
-- chain deferred — engine ask #1).

CREATE OR REPLACE FUNCTION ckp.concept_match(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $cm$
DECLARE
  v_term  text := p_payload->>'term';
  v_limit int  := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 10), 1), 100);
  v_rows  jsonb;
BEGIN
  IF v_term IS NULL OR length(v_term) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'term', v_term);
  END IF;
  -- SEALED query (pgCK-authored). Ranked: exact (1) > prefix (2) > contains (3). v_term/v_limit
  -- are plpgsql variables → auto-bound; the caller never supplies the query text.
  SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
  INTO v_rows FROM (
    SELECT id, body->>'rdfs:label' AS lbl,
      CASE WHEN lower(body->>'rdfs:label') = lower(v_term)            THEN 1
           WHEN lower(body->>'rdfs:label') LIKE lower(v_term)||'%'    THEN 2
           ELSE 3 END AS rnk
    FROM ckp.instances
    WHERE body->>'rdfs:label' ILIKE '%'||v_term||'%'
    ORDER BY rnk
    LIMIT v_limit
  ) t;
  RETURN jsonb_build_object('ok', true, 'term', v_term,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'candidates', COALESCE(v_rows, '[]'::jsonb));
END;
$cm$;

CREATE OR REPLACE FUNCTION ckp.explain(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $ex$
DECLARE
  v_id   text := p_payload->>'id';
  v_body jsonb;
  v_mat  jsonb;
BEGIN
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  -- direct-vs-inferred from the engine is_inferred column (graph-wide summary for the alpha;
  -- the per-node derivation chain is deferred — engine ask #1).
  BEGIN
    SELECT jsonb_build_object('direct',   count(*) FILTER (WHERE NOT is_inferred),
                              'inferred', count(*) FILTER (WHERE is_inferred))
    INTO v_mat FROM pgrdf._pgrdf_quads;
  EXCEPTION WHEN OTHERS THEN
    v_mat := jsonb_build_object('note', 'is_inferred available; counts unavailable: '||SQLERRM);
  END;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'materialization', v_mat,
                            'derivation_chain', 'deferred (engine ask #1)');
END;
$ex$;

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','concept.match',    'input.kernel.pgCK.action.concept.match',    'instance'),
  ('pgCK','instance.explain', 'input.kernel.pgCK.action.instance.explain', 'instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane='instance';

ALTER FUNCTION ckp.concept_match(jsonb) OWNER TO ck_substrate;
ALTER FUNCTION ckp.explain(jsonb)       OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
