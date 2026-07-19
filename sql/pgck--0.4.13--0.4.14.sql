-- ============================================================================
-- pgck 0.4.13 -> 0.4.14 — STABILIZATION: authorized CK-loop writer + uniform id-form
-- ============================================================================
-- Two real, third-party-confirmed (CK.Lib.Js verify-v160 + a downstream-consumer SPIKE, live wire)
-- bugs that the "✅ attested" T1–T6 markers hid. Neither is a new feature; both make
-- the EXISTING typed surface actually do what was claimed. No federation, no new verbs.
--
--   (#18) THE CK-LOOP WAS UNAUTHORED ON THE DEMO. The typed ops (create_typed/query/
--   update/validate + the seal gate) read shapes from `urn:ckp:<proj>/kernel/ck`, but the
--   documented bootstrap (`import_module`) seals them into `…/kernel/board` — a different
--   graph — so `/ck` is empty and every gate no-ops (`ok:true` doing nothing the types
--   declare). In three-loops terms this is a Separation-Axiom violation: a TOOL-shaped
--   bootstrap left the CK loop unauthored. `load_kernel` already writes `/ck` correctly but
--   needs a file mount; oci-germination asked for a SUPPORTED, file-mount-free call (they
--   will not shim init.sql or hand-write `/ck`). `ckp.adopt_kernel_ttl(ttl, project)` is that
--   authorized CK-loop writer: it seals a kernel/type shape (TTL string) into the project's
--   own `/ck`, additively + idempotently. Operator-level (first-boot), NOT a dispatch verb —
--   `ck_participant` still cannot write `/ck`, so the axiom holds.
--
--   (#2/#3) ID-FORM WAS INCONSISTENT ACROSS THE VERB SURFACE. `create` returns a BARE id,
--   `get`/`link` accept bare, `provenance` REQUIRES bare — but `reach`/`materialize_edge`
--   choke on bare (a bare id is a relative IRI → SPARQL parse error / no traversable quad →
--   `reachable:false`), so the client's link→reach round-trip is DEAD on the ids it actually
--   holds. `ckp._resolve_ref` resolves a bare id to its stamped `@id` (the IRI link & reach
--   must agree on); `reach` resolves `from`, `materialize_edge` resolves source+target — so
--   the round-trip works whether the caller passes a bare id or the full `@id`.
--
-- Exit tests: s49_adopt_kernel_ttl (sanctioned writer restores enforcement THROUGH the
-- dispatch door) · s50_bare_id_roundtrip (bare-id link→reach reaches the target).
-- ============================================================================

-- ---- (#18) ckp.adopt_kernel_ttl — the authorized, file-mount-free CK-loop writer ----
-- Seals a kernel/type shape (TTL string) into urn:ckp:<project>/kernel/ck — the graph the
-- typed ops + seal gate read. Additive (no clear): adopt task.ttl then goal.ttl accumulates;
-- RDF set-semantics make re-adoption idempotent. The bootstrap-time counterpart to governance
-- `apply` (which owns /ck after bootstrap); ck_substrate-owned, so unreachable by ck_participant.
CREATE OR REPLACE FUNCTION ckp.adopt_kernel_ttl(p_ttl text, p_project text DEFAULT 'demo')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $akt$
DECLARE
  v_iri   text := format('urn:ckp:%s/kernel/ck', p_project);
  v_g     bigint;
  v_quads bigint;
BEGIN
  IF p_ttl IS NULL OR btrim(p_ttl) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ttl_required');
  END IF;
  -- get-or-create the project's CK-loop graph (after ckp.boot has claimed the reserved
  -- core/kernel ids, so the IRI-variant add_graph never steals id 1/2 — the s34 lesson).
  v_g := pgrdf.add_graph(v_iri);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_g, v_iri || '#');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'detail', SQLERRM);
  END;
  PERFORM pgrdf.materialize(v_g);
  RETURN jsonb_build_object('ok', true, 'project', p_project, 'ck_iri', v_iri,
                            'kernel_graph', v_g, 'quads', v_quads);
END;
$akt$;
ALTER FUNCTION ckp.adopt_kernel_ttl(text, text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.adopt_kernel_ttl(text, text) IS
  'v0.4.14 (#18 fix): the authorized, file-mount-free CK-loop writer — seal a kernel/type shape (TTL '
  'string) additively + idempotently into urn:ckp:<project>/kernel/ck (the graph the typed ops + seal '
  'gate read). The supported bootstrap call oci-germination asked for; operator-level, NOT a dispatch '
  'verb, so the Three-Loop Separation Axiom holds (ck_participant cannot write the CK loop).';

-- ---- (#2/#3) ckp._resolve_ref — bare instance id -> its stamped @id IRI -------------
-- The single source of id-form truth: an absolute IRI passes through; a bare id resolves to the
-- instance's stamped @id (what create_typed / the Task/Goal/Edge seal paths write), with a stable
-- deterministic fallback for a known instance lacking @id. reach + materialize_edge both call this,
-- so a bare id and its @id resolve identically and the link->reach round-trip connects either way.
CREATE OR REPLACE FUNCTION ckp._resolve_ref(p_ref text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $rr$
DECLARE v_iri text;
BEGIN
  IF p_ref IS NULL OR btrim(p_ref) = '' THEN RETURN NULL; END IF;
  -- already an absolute IRI (has a scheme — urn:…, ckp://…, https://…): use as-is.
  IF position(':' in p_ref) > 0 THEN RETURN p_ref; END IF;
  -- bare id: the instance's stamped @id is the IRI link + reach agree on.
  SELECT body->>'@id' INTO v_iri FROM ckp.instances WHERE id = p_ref;
  IF v_iri IS NOT NULL AND position(':' in v_iri) > 0 THEN RETURN v_iri; END IF;
  -- known instance without a stamped @id: a stable, deterministic fallback IRI.
  IF EXISTS (SELECT 1 FROM ckp.instances WHERE id = p_ref) THEN
    RETURN 'urn:ckp:instance:' || p_ref;
  END IF;
  RETURN NULL;   -- unknown bare id: unresolvable; caller decides (reach -> [], link -> no quad).
END;
$rr$;
ALTER FUNCTION ckp._resolve_ref(text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp._resolve_ref(text) IS
  'v0.4.14 (id-form): resolve a bare instance id to its stamped @id IRI (absolute IRIs pass through). '
  'The shared resolver for reach + materialize_edge so the bare-id client flow round-trips like the @id form.';

-- ---- ckp.reach — resolve a bare `from` before the property-path SPARQL --------------
-- (T2 declared-predicate gate unchanged; only `from` now resolves through _resolve_ref so a bare
-- instance id traverses instead of SPARQL-parse-erroring as a relative IRI.)
CREATE OR REPLACE FUNCTION ckp.reach(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $reach$
DECLARE
  v_from     text := p_payload->>'from';
  v_from_iri text;
  v_via      text := p_payload->>'via';
  v_proj     text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_max      int  := COALESCE(NULLIF(current_setting('pgrdf.path_max_depth', true),'')::int, 0);
  v_declared jsonb;
  v_reached  jsonb;
BEGIN
  IF v_from IS NULL OR btrim(v_from) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from);
  END IF;
  -- id-form: a bare instance id resolves to its @id IRI (the form link/materialize_edge wrote);
  -- an absolute IRI passes through. An unresolvable bare id has nothing to reach FROM.
  v_from_iri := ckp._resolve_ref(v_from);
  IF v_from_iri IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'from', v_from, 'resolved', NULL, 'via', v_via,
                              'max_depth', v_max, 'reached', '[]'::jsonb);
  END IF;
  IF v_from_iri !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_from', 'from', v_from, 'resolved', v_from_iri);
  END IF;
  -- injection-safe IRI gate on `via` (always).
  IF v_via IS NULL OR v_via !~ v_iri_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- T2: `via` MUST be in the kernel's DECLARED predicate set; a kernel that declares none falls
  -- back to the namespace allowlist (back-compat).
  v_declared := ckp.declared_predicates(v_proj);
  IF jsonb_array_length(v_declared) > 0 THEN
    IF NOT (v_declared @> to_jsonb(v_via)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via, 'declared', v_declared);
    END IF;
  ELSIF NOT (v_via LIKE 'https://conceptkernel.org/%' OR v_via LIKE 'urn:ckp:%') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'undeclared_predicate', 'via', v_via);
  END IF;
  -- bounded transitive traversal over the materialized link quads — `+` engine-capped.
  SELECT jsonb_agg(DISTINCT j->>'r') INTO v_reached
  FROM pgrdf.sparql(format('SELECT ?r WHERE { GRAPH ?g { <%s> <%s>+ ?r } }', v_from_iri, v_via)) j;
  RETURN jsonb_build_object('ok', true, 'from', v_from, 'resolved', v_from_iri, 'via', v_via,
                            'max_depth', v_max, 'reached', COALESCE(v_reached, '[]'::jsonb));
END;
$reach$;
ALTER FUNCTION ckp.reach(jsonb) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.reach(jsonb) IS
  'T2 (v0.4.9) + v0.4.14 id-form: instance.reach — `from` resolves through ckp._resolve_ref (bare id -> '
  '@id IRI), `via` gated on the kernel''s declared predicate set (namespace fallback). Traverses the '
  'materialized link quads (v0.4.6); the bare-id client flow now round-trips.';

-- ---- ckp.materialize_edge — resolve bare source/target before writing the quad ------
-- Endpoints now resolve through _resolve_ref, so an edge created with BARE ids (the ids create
-- returns) materializes a traversable quad on the instances' @id IRIs — instead of silently
-- sealing the Edge with no quad (reachable:false). An unresolvable endpoint still gets no quad.
CREATE OR REPLACE FUNCTION ckp.materialize_edge(p_src text, p_pred text, p_tgt text, p_project text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $me$
DECLARE
  v_iri_re text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';   -- no quote/space/newline/'>' reaches the TTL
  v_src    text := ckp._resolve_ref(p_src);           -- bare id -> @id IRI (else NULL)
  v_tgt    text := ckp._resolve_ref(p_tgt);
  v_pred   text := CASE WHEN position(':' in COALESCE(p_pred,'')) > 0
                        THEN p_pred                                     -- already an IRI: as-is
                        ELSE 'https://conceptkernel.org/ontology/v3.7/' || p_pred END;  -- short -> v3.7 IRI
  v_g      bigint;
BEGIN
  -- materialize only when both endpoints resolved to clean absolute IRIs (all three injection-gated).
  IF v_src IS NULL OR v_tgt IS NULL
     OR position(':' in v_src) = 0 OR position(':' in v_tgt) = 0
     OR v_src !~ v_iri_re OR v_pred !~ v_iri_re OR v_tgt !~ v_iri_re THEN
    RETURN false;
  END IF;
  v_g := pgrdf.add_graph(format('urn:ckp:%s/edges', p_project));   -- per-project edge graph (get-or-create)
  PERFORM pgrdf.parse_turtle(format('<%s> <%s> <%s> .', v_src, v_pred, v_tgt),
                             v_g, format('urn:ckp:%s/edges#', p_project));
  RETURN true;
END;
$me$;
ALTER FUNCTION ckp.materialize_edge(text, text, text, text) OWNER TO ck_substrate;

COMMENT ON FUNCTION ckp.materialize_edge(text, text, text, text) IS
  'Tier 2 (3/3a) + v0.4.14 id-form: on edge.create/link, resolve source+target through ckp._resolve_ref '
  '(bare id -> @id IRI) and write the traversable quad into urn:ckp:<project>/edges so reach finds the '
  'link whether the caller passed a bare id or the @id. IRI-gated; an unresolvable endpoint gets no quad.';

-- ---- closing floor pass ------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
