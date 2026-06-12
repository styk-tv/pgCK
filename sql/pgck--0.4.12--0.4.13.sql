-- ============================================================================
-- pgck 0.4.12 -> 0.4.13 — v0.5 roadmap T6: governed concept.match
-- ============================================================================
-- The built-in `concept.match` was a hardcoded label search over `ckp.instances`.
-- v3.9 §6.3 specifies the GOVERNED form: the query text is a sealed kernel fact,
-- compiled into `ckp.plans`, and the caller binds parameters only — never the query.
--
-- T6 converts the built-in to that form while keeping its `{term, count, candidates}`
-- reply, in three parts:
--   1. PROJECTION — a trigger projects each label-bearing instance to the per-project
--      graph `urn:ckp:<project>/instances` (`<@id> a <type> ; rdfs:label "<label>"`) so a
--      SPARQL label search can find it. (Reuses the same label-coalesce concept.match used.)
--   2. SEED — the canonical `concept.match` SPARQL query (label search over the instance
--      graph, param `term`) is seeded as a governed plan in `ckp.plans` at install.
--   3. EXECUTION — `ckp.concept_match` reads its governed plan, validates + binds the `term`
--      (and the project graph) into the sealed query, runs it via `pgrdf.sparql`, and reshapes
--      rows → ranked `candidates`. Falls back to the legacy in-table search when no plan exists.
--
-- The query text is now a governed fact (a kernel can supersede it via a higher-epoch plan);
-- callers still pass only `{term}`. Caveats: a re-seal re-projects (DISTINCT dedups by id+label;
-- a changed label leaves a stale triple — acceptable for label search); ranking is simplified to
-- contains-ordered-by-label.
--
-- Exit test: sql/test/s47_governed_concept_match.sql.
-- ============================================================================

-- ---- (1) projection: label-bearing instances -> urn:ckp:<project>/instances ----
CREATE OR REPLACE FUNCTION ckp.project_instance_label()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $pil$
DECLARE
  N      text := 'https://conceptkernel.org/ontology/v3.7/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  v_type text := NEW.body->>'type';
  v_id   text := COALESCE(NEW.body->>'@id', 'urn:ckp:instance:'||NEW.id);
  v_lbl  text;
  v_proj text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_g    bigint;
BEGIN
  v_lbl := COALESCE(NEW.body->>RL, NEW.body->>'rdfs:label',
                    NEW.body->>(N||'title'), NEW.body->>'title',
                    NEW.body->>(N||'name'), NEW.body->>'name');
  -- only label-bearing, well-formed instances are projected (Proposals/Votes/Edges have no label).
  IF v_lbl IS NULL OR v_type IS NULL OR v_id !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN NEW;
  END IF;
  BEGIN
    -- DETERMINISTIC HIGH graph id per project (NOT the IRI-variant auto-id, which assigns the lowest
    -- free id and would steal the reserved core(1)/kernel(2) ids if a write lands before ckp.boot — the
    -- s34 fresh-cluster failure). 1.3e9 + hash keeps it clear of every auto-assigned scratch/board id.
    v_g := 1300000000 + (abs(hashtext(format('urn:ckp:%s/instances', v_proj))) % 90000000);
    PERFORM pgrdf.add_graph(v_g, format('urn:ckp:%s/instances', v_proj));
    PERFORM pgrdf.parse_turtle(
      format('<%s> a <%s> ; <%s> "%s" .', v_id, v_type, RL,
             replace(replace(v_lbl, '\', '\\'), '"', '\"')),
      v_g, format('urn:ckp:%s/instances#', v_proj));
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- projection is a search index, never a write-path gate: a failure must not fail the seal.
  END;
  RETURN NEW;
END;
$pil$;
ALTER FUNCTION ckp.project_instance_label() OWNER TO ck_substrate;
-- NOTE: the AFTER INSERT/UPDATE trigger on ckp.instances is created in the install-completeness
-- file (the LAST include, which creates ckp.instances at install) so the table exists first; it is
-- re-asserted there idempotently.

-- ---- (2) seed the governed concept.match query into ckp.plans ------------------
-- $graph$ is bound to the project instance graph and $term$ to the validated search term
-- by ckp.concept_match at run time; the query text itself is the governed fact.
INSERT INTO ckp.plans(kernel, verb, epoch, plan)
VALUES ('pgCK', 'concept.match', 1, jsonb_build_object(
  'kind', 'sparql',
  'params', jsonb_build_array('term'),
  'statement',
    'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> '
    || 'SELECT ?id ?label WHERE { GRAPH <$graph$> { ?id rdfs:label ?label . '
    || 'FILTER(CONTAINS(LCASE(STR(?label)), LCASE("$term$"))) } } ORDER BY ?label'))
ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

-- ---- (3) ckp.concept_match — run the GOVERNED plan (legacy in-table fallback) ----
CREATE OR REPLACE FUNCTION ckp.concept_match(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $cm$
DECLARE
  v_term   text := p_payload->>'term';
  v_proj   text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_limit  int  := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 10), 1), 100);
  v_term_esc text;
  v_plan   jsonb;
  v_stmt   text;
  v_rows   jsonb;
BEGIN
  IF v_term IS NULL OR length(v_term) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'term', v_term);
  END IF;

  -- the GOVERNED query: latest-epoch concept.match plan.
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel = 'pgCK' AND verb = 'concept.match' ORDER BY epoch DESC LIMIT 1;

  IF v_plan IS NOT NULL AND v_plan->>'kind' = 'sparql' THEN
    -- BIND (not reject): escape the term for the SPARQL string literal so any term is contained —
    -- an injection-shaped term becomes a literal that matches nothing (never breaks the query).
    v_term_esc := replace(replace(replace(v_term, '\', '\\'), '"', '\"'), chr(10), '\n');
    v_stmt := replace(v_plan->>'statement', '$graph$', format('urn:ckp:%s/instances', v_proj));
    v_stmt := replace(v_stmt, '$term$', v_term_esc);
    -- run + RANK in pgCK (exact > prefix > contains; the governed query supplies the matches).
    SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
      INTO v_rows
    FROM (
      SELECT j->>'id' AS id, j->>'label' AS lbl,
        CASE WHEN lower(j->>'label') = lower(v_term)         THEN 1
             WHEN lower(j->>'label') LIKE lower(v_term)||'%' THEN 2
             ELSE 3 END AS rnk
      FROM pgrdf.sparql(v_stmt) j
      LIMIT v_limit
    ) t;
    RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', true,
                              'count', COALESCE(jsonb_array_length(v_rows), 0),
                              'candidates', COALESCE(v_rows, '[]'::jsonb));
  END IF;

  -- fallback: the legacy in-table label search (no governed plan present).
  SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
  INTO v_rows FROM (
    SELECT id, lbl,
      CASE WHEN lower(lbl) = lower(v_term)         THEN 1
           WHEN lower(lbl) LIKE lower(v_term)||'%' THEN 2
           ELSE 3 END AS rnk
    FROM (
      SELECT id, COALESCE(body->>'rdfs:label',
                          body->>'https://conceptkernel.org/ontology/v3.7/title',
                          body->>'title') AS lbl
      FROM ckp.instances
    ) s
    WHERE lbl ILIKE '%'||v_term||'%'
    ORDER BY rnk
    LIMIT v_limit
  ) t;
  RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', false,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'candidates', COALESCE(v_rows, '[]'::jsonb));
END;
$cm$;
ALTER FUNCTION ckp.concept_match(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.concept_match(jsonb) IS
  'T6 (v0.4.13): governed concept.match — runs its SEALED query from ckp.plans (label search over the '
  'per-project instance graph, projected by the ckp.instances label trigger), binding only the validated '
  'term; legacy in-table search as fallback. The query text is a governed fact; callers pass only {term}.';

-- ---- closing floor pass ------------------------------------------------------
ALTER FUNCTION ckp.project_instance_label() OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
