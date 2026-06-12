-- ============================================================================
-- pgck 0.4.8 -> 0.4.9 — v0.5 roadmap T2: link/reach declared predicate set
-- ============================================================================
-- `ckp.reach` and `edge.create` gated the predicate by a NAMESPACE allowlist
-- (`conceptkernel.org/% OR urn:ckp:%`) — the §6.2 concretion. T2 makes the kernel's
-- own DECLARED predicate set the gate: the predicates it declares as `sh:path` in its
-- kernel graph (addable via the governance plane). An undeclared predicate is rejected
-- even when it sits in the conceptkernel namespace.
--
-- Back-compat (same shaped/unshaped fallback as T1): a kernel that declares NO
-- predicates keeps the namespace allowlist — so existing links/reaches over the core
-- relations (e.g. the s30/s40 fixtures, which declare no kernel predicates) are
-- unchanged. The IRI regex gate stays for injection safety in both modes.
--
-- Exit test: sql/test/s43_declared_predicates.sql — a kernel declaring `part_of`:
-- link(A,part_of,B) seals + materializes, reach(A,part_of) returns B; an undeclared
-- predicate is rejected by both link and reach even in the conceptkernel namespace.
-- ============================================================================

-- ---- ckp.declared_predicates — the kernel's declared predicate IRI set ----------
CREATE OR REPLACE FUNCTION ckp.declared_predicates(p_project text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $dp$
  SELECT COALESCE(jsonb_agg(DISTINCT p), '[]'::jsonb)
  FROM (
    SELECT j->>'p' AS p
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?p WHERE { GRAPH <urn:ckp:%s/kernel/ck> { ?s sh:property ?prop . ?prop sh:path ?p } }
    $q$, p_project)) j
    WHERE j->>'p' IS NOT NULL
  ) d;
$dp$;
ALTER FUNCTION ckp.declared_predicates(text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.declared_predicates(text) IS
  'T2 (v0.4.9): the kernel''s declared predicate IRI set — the union of sh:path over its kernel-graph '
  'shapes. The gate for instance.link / instance.reach when non-empty; empty → namespace-allowlist fallback.';

-- ---- ckp.reach — gate `via` on the declared predicate set (namespace fallback) ----
CREATE OR REPLACE FUNCTION ckp.reach(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $reach$
DECLARE
  v_from    text := p_payload->>'from';
  v_via     text := p_payload->>'via';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_iri_re  text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_max     int  := COALESCE(NULLIF(current_setting('pgrdf.path_max_depth', true),'')::int, 0);
  v_declared jsonb;
  v_reached jsonb;
BEGIN
  IF v_from IS NULL OR v_from !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from);
  END IF;
  -- injection-safe IRI gate (always).
  IF v_via IS NULL OR v_via !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- T2: `via` MUST be in the kernel's DECLARED predicate set (registry-checked, not parsed);
  -- a kernel that declares none falls back to the namespace allowlist (back-compat).
  v_declared := ckp.declared_predicates(v_proj);
  IF jsonb_array_length(v_declared) > 0 THEN
    IF NOT (v_declared @> to_jsonb(v_via)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via, 'declared', v_declared);
    END IF;
  ELSIF NOT (v_via LIKE 'https://conceptkernel.org/%' OR v_via LIKE 'urn:ckp:%') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- bounded transitive traversal — `+` is engine-capped at pgrdf.path_max_depth.
  SELECT jsonb_agg(DISTINCT j->>'r') INTO v_reached
  FROM pgrdf.sparql(format('SELECT ?r WHERE { GRAPH ?g { <%s> <%s>+ ?r } }', v_from, v_via)) j;
  RETURN jsonb_build_object('ok', true, 'from', v_from, 'via', v_via,
                            'max_depth', v_max, 'reached', COALESCE(v_reached, '[]'::jsonb));
END;
$reach$;
ALTER FUNCTION ckp.reach(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.reach(jsonb) IS
  'T2 (v0.4.9): instance.reach — bounded transitive traversal; `via` gated on the kernel''s DECLARED '
  'predicate set (ckp.declared_predicates), namespace-allowlist fallback when the kernel declares none. '
  'Traverses materialized link quads (v0.4.6).';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
