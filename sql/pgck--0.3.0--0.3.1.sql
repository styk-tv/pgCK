-- pgck 0.3.0 -> 0.3.1 — CKP v3.9 Track B (sealed registry + typed dispatch).
-- This migration accretes Track B's SQL across CI-B-4 / CI-B-3 / CI-B-2; v0.3.1 ships at
-- the CI-B-1 flip. Track B does NOT yet replace the live web2 verb dispatch — the registry
-- here is the MECHANISM (table + refresh + exact-match lookup); CI-B-2/CI-B-1 route through
-- it. So v0.3.0 web2 consumers stay working.

-- ============================================================================
-- CI-B-4 (index 19) — the exact-match sealed registry.
-- ============================================================================
-- v3.9 §2.2(1): "verb × kernel_urn exact-matched against sealed affordance rows. No LIKE,
-- no dynamic evaluation, no fallthrough." The registry is a DERIVED relational index over
-- the sealed affordance FACTS (the kernel's ckp:Affordance triples) — deliberately not graph
-- facts. Keyed (kernel, verb); verb derived from the affordance's inTopic
-- (input.kernel.<Kernel>.action.<verb>). Carries plane / inShape / epoch / delegate.

CREATE TABLE IF NOT EXISTS ckp.affordance_registry (
  kernel         text        NOT NULL,
  verb           text        NOT NULL,
  affordance_iri text,
  in_topic       text        NOT NULL,
  out_topic      text,
  in_shape       text,
  plane          text        NOT NULL DEFAULT 'instance',
  epoch          integer     NOT NULL DEFAULT 1,
  delegate       boolean     NOT NULL DEFAULT false,
  refreshed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kernel, verb)
);

COMMENT ON TABLE ckp.affordance_registry IS
  'CI-B-4: derived exact-match registry index over the sealed ckp:Affordance facts, keyed '
  '(kernel, verb). The routing authority for ckp.dispatch (wired in CI-B-2). Rebuilt by '
  'ckp.registry_refresh() at load/apply; NOT a graph fact.';

-- ---- ckp.registry_refresh() — rebuild the index from the sealed affordance facts --------
-- Ring-1: reads pgrdf as ck_substrate (definer). Idempotent (upsert by (kernel, verb)).
CREATE OR REPLACE FUNCTION ckp.registry_refresh()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $refresh$
DECLARE
  r          record;
  v_kernel   text;
  v_verb     text;
  v_epoch    integer;
  v_delegate boolean;
  v_count    integer := 0;
BEGIN
  FOR r IN
    SELECT j->>'a'  AS iri,
           j->>'it' AS in_topic,
           j->>'ot' AS out_topic,
           j->>'is' AS in_shape,
           j->>'pl' AS plane,
           j->>'ep' AS epoch,
           j->>'dg' AS delegate
    FROM pgrdf.sparql($q$
      PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
      SELECT ?a ?it ?ot ?is ?pl ?ep ?dg WHERE {
        GRAPH ?g {
          ?a a ckp:Affordance ; ckp:inTopic ?it .
          OPTIONAL { ?a ckp:outTopic ?ot }
          OPTIONAL { ?a ckp:inShape  ?is }
          OPTIONAL { ?a ckp:plane    ?pl }
          OPTIONAL { ?a ckp:epoch    ?ep }
          OPTIONAL { ?a ckp:delegate ?dg }
        } }
    $q$) AS j
  LOOP
    -- derive kernel + verb from inTopic: input.kernel.<Kernel>.action.<verb>
    v_kernel := substring(r.in_topic FROM '^input\.kernel\.([^.]+)\.action\.');
    v_verb   := regexp_replace(r.in_topic, '^input\.kernel\.[^.]+\.action\.', '');
    CONTINUE WHEN v_kernel IS NULL OR v_verb IS NULL OR v_verb = r.in_topic OR v_verb = '';

    -- typed-literal-safe parses (strip any ^^<datatype> suffix the engine may carry)
    v_epoch    := COALESCE(NULLIF(split_part(COALESCE(r.epoch,    ''), '^', 1), '')::integer, 1);
    v_delegate := COALESCE(NULLIF(split_part(COALESCE(r.delegate, ''), '^', 1), '')::boolean, false);

    INSERT INTO ckp.affordance_registry
      (kernel, verb, affordance_iri, in_topic, out_topic, in_shape, plane, epoch, delegate, refreshed_at)
    VALUES
      (v_kernel, v_verb, r.iri, r.in_topic, r.out_topic, r.in_shape,
       COALESCE(NULLIF(split_part(COALESCE(r.plane,''),'^',1),''), 'instance'),
       v_epoch, v_delegate, now())
    ON CONFLICT (kernel, verb) DO UPDATE SET
      affordance_iri = EXCLUDED.affordance_iri,
      in_topic   = EXCLUDED.in_topic,
      out_topic  = EXCLUDED.out_topic,
      in_shape   = EXCLUDED.in_shape,
      plane      = EXCLUDED.plane,
      epoch      = EXCLUDED.epoch,
      delegate   = EXCLUDED.delegate,
      refreshed_at = EXCLUDED.refreshed_at;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$refresh$;

COMMENT ON FUNCTION ckp.registry_refresh() IS
  'CI-B-4: (re)build ckp.affordance_registry from the sealed ckp:Affordance facts. SECURITY '
  'DEFINER as ck_substrate. Returns the count of affordances indexed.';

-- ---- ckp.registry_lookup(kernel, verb) — the exact-match routing decision ----------------
-- Parameterized equality only: no LIKE, no dynamic eval, no fallthrough. Returns the
-- affordance row as JSONB, or NULL when the verb is not a sealed affordance (the basis for
-- {ok:false, error:'unknown_affordance'} in dispatch). A row with delegate=true is the
-- sealed delegation fact behind {delegate:true} — distinct from a missing verb.
CREATE OR REPLACE FUNCTION ckp.registry_lookup(p_kernel text, p_verb text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $lookup$
  SELECT to_jsonb(r) FROM ckp.affordance_registry r
  WHERE r.kernel = p_kernel AND r.verb = p_verb;
$lookup$;

COMMENT ON FUNCTION ckp.registry_lookup(text, text) IS
  'CI-B-4: exact-match (kernel, verb) → affordance row JSONB, or NULL if unknown. '
  'Parameterized equality only (no LIKE/dynamic eval). SECURITY DEFINER as ck_substrate.';

-- ---- floor the new objects (ADP is unreliable inside CREATE EXTENSION) --------------------
ALTER FUNCTION ckp.registry_refresh()             OWNER TO ck_substrate;
ALTER FUNCTION ckp.registry_lookup(text, text)    OWNER TO ck_substrate;
REVOKE ALL ON ckp.affordance_registry FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  ALL     ON ckp.affordance_registry      TO ck_substrate;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp  TO ck_substrate;

-- ============================================================================
-- CI-B-3 (index 18) — the ValidationReport shape gate.
-- ============================================================================
-- v3.9 §2.2(4): the payload is validated against the affordance's inShape BEFORE any
-- value is used, and the engine's sh:ValidationReport is surfaced as typed violations[]
-- — closing rc-07 (the boolean-only ckp.validate) as an INTEGRATION (the engine already
-- produces the report; ckp.validate just discarded it). The dispatch route (CI-B-2) calls
-- this before binding any payload value.
--
-- ckp.validate_report(ttl, shapes_graph) → { conforms: bool, violations: [ <report rows> ] }.
-- Routes through the Ring-1 _validate primitive (CI-A-3), so the engine is reached only as
-- ck_substrate. Returns field-level diagnostics from day one.
CREATE OR REPLACE FUNCTION ckp.validate_report(p_ttl text, p_shapes_graph integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $vreport$
DECLARE
  v_scratch integer := 1100000000 + pg_backend_pid();
  v_report  jsonb;
BEGIN
  PERFORM pgrdf.add_graph(v_scratch, format('urn:ckp:vreport-scratch:%s', v_scratch));
  PERFORM pgrdf.clear_graph(v_scratch);
  PERFORM pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:vreport#');
  v_report := ckp._validate(v_scratch, p_shapes_graph);   -- Ring-1: full sh:ValidationReport
  PERFORM pgrdf.clear_graph(v_scratch);
  RETURN jsonb_build_object(
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb));
END;
$vreport$;

COMMENT ON FUNCTION ckp.validate_report(text, integer) IS
  'CI-B-3: shape gate — validate a payload (TTL) against a shapes graph via Ring-1 _validate '
  'and return { conforms, violations[] } from the engine sh:ValidationReport. Closes rc-07.';

ALTER FUNCTION ckp.validate_report(text, integer) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-B-2 (index 17) — plane route + verb migration (task.* → instance.*).
-- ============================================================================
-- The dispatch surface migrates to v3.9 instance.* names; the legacy names stay as aliases
-- for one minor (CK.Lib.Js confirmed the op→verb table 2026-06-10: kernel.create →
-- instance.create ONLY; register instance.validate). Two pure resolvers + a seeded core
-- registry drive a NON-BREAKING preamble in ckp.dispatch (sql/dispatch.sql): the CASE
-- handlers are unchanged — v0.3.0 web2 keeps working — while instance.* names route to them,
-- and governance-plane verbs are plane-rejected (the propose stub; CI-D executes them).

-- legacy → canonical instance.* name (drives the registry plane lookup).
CREATE OR REPLACE FUNCTION ckp.verb_canon(p_verb text)
RETURNS text LANGUAGE sql IMMUTABLE AS $canon$
  SELECT CASE p_verb
    WHEN 'task.create'     THEN 'instance.create'
    WHEN 'kernel.create'   THEN 'instance.create'   -- CK.Lib.Js fix: instance, not propose
    WHEN 'edge.create'     THEN 'instance.link'
    WHEN 'task.update'     THEN 'instance.update'
    WHEN 'instances.list'  THEN 'instance.query'
    WHEN 'instances.last'  THEN 'instance.query'
    WHEN 'instances.count' THEN 'instance.query'
    WHEN 'snapshot.board'  THEN 'instance.snapshot'
    WHEN 'snapshot.bodies' THEN 'instance.snapshot'
    WHEN 'provenance'      THEN 'instance.provenance'
    ELSE p_verb   -- instance.* / kernel.* / participant.join / affordances / kernels.list pass through
  END;
$canon$;

-- canonical/instance.* → the legacy handler name the dispatch CASE implements (alias window).
-- instance.create routes by payload to the type-specific seal (Task vs Goal/kernel).
CREATE OR REPLACE FUNCTION ckp.verb_to_legacy(p_verb text, p_payload jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $tolegacy$
  SELECT CASE p_verb
    WHEN 'instance.create' THEN
      CASE WHEN p_payload ? 'task' THEN 'task.create'
           WHEN p_payload ? 'name' THEN 'kernel.create'
           ELSE 'task.create' END
    WHEN 'instance.update'     THEN 'task.update'
    WHEN 'instance.link'       THEN 'edge.create'
    WHEN 'instance.snapshot'   THEN 'snapshot.board'
    WHEN 'instance.query'      THEN 'instances.list'
    WHEN 'instance.provenance' THEN 'provenance'
    ELSE p_verb   -- legacy names + instance.get / instance.verify pass straight through
  END;
$tolegacy$;

-- Seed pgCK's CORE verb surface into the registry (kernel='pgCK'): instance.* = instance
-- plane; the governance verbs = governance plane (plane-rejected until CI-D lands them).
INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','instance.create',      'input.kernel.pgCK.action.instance.create',      'instance'),
  ('pgCK','instance.update',      'input.kernel.pgCK.action.instance.update',      'instance'),
  ('pgCK','instance.link',        'input.kernel.pgCK.action.instance.link',        'instance'),
  ('pgCK','instance.query',       'input.kernel.pgCK.action.instance.query',       'instance'),
  ('pgCK','instance.get',         'input.kernel.pgCK.action.instance.get',         'instance'),
  ('pgCK','instance.verify',      'input.kernel.pgCK.action.instance.verify',      'instance'),
  ('pgCK','instance.snapshot',    'input.kernel.pgCK.action.instance.snapshot',    'instance'),
  ('pgCK','instance.provenance',  'input.kernel.pgCK.action.instance.provenance',  'instance'),
  ('pgCK','instance.validate',    'input.kernel.pgCK.action.instance.validate',    'instance'),
  ('pgCK','kernel.propose_change','input.kernel.pgCK.action.kernel.propose_change','governance'),
  ('pgCK','kernel.vote',          'input.kernel.pgCK.action.kernel.vote',          'governance'),
  ('pgCK','kernel.apply',         'input.kernel.pgCK.action.kernel.apply',         'governance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane = EXCLUDED.plane, in_topic = EXCLUDED.in_topic;

ALTER FUNCTION ckp.verb_canon(text)            OWNER TO ck_substrate;
ALTER FUNCTION ckp.verb_to_legacy(text, jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-B-1 (index 16) — the registry as the SOLE routing authority (Track B flip).
-- ============================================================================
-- Complete the registry: seed pgCK's remaining read/participant verbs so EVERY shipped verb
-- resolves through the registry. The dispatch (sql/dispatch.sql) now rejects any verb absent
-- from the registry with {ok:false, error:'unknown_affordance'} (zero payload evaluation) —
-- no fallthrough — while a delegate=true row is the sealed delegation seam.
INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','affordances',     'input.kernel.pgCK.action.affordances',      'instance'),
  ('pgCK','kernels.list',    'input.kernel.pgCK.action.kernels.list',     'instance'),
  ('pgCK','participant.join','input.kernel.pgCK.action.participant.join', 'instance'),
  ('pgCK','notify',          'input.kernel.pgCK.action.notify',           'instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane = EXCLUDED.plane, in_topic = EXCLUDED.in_topic;
