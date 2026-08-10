-- pgck 0.4.34 -> 0.4.35 — A2: composition becomes ADOPTION-DERIVED (PASS-25 §6),
-- and the upgrade route re-hardens the ring (B2).
--
-- A2. ckp._composed_shapes was hardcoded core ∪ kernel, which is why the v3.11
-- root sat MATERIALIZED on the bench in a graph the gate never read while the
-- seal validated against v3.8 shapes — adoption-by-proximity, the exact thing
-- §2 forbids ("proximity is not adoption"). Composition is now derived from
-- SEALED ADOPTIONS:
--
--   composed = kernel graph
--            ∪ ε0 core graph            (urn:ckp:core — the one file-loaded floor)
--            ∪ { graph(m) : a sealed, unsuperseded ckp:Adoption in this project
--                           carries ckp:adopts = m }
--
-- MODULE-IRI-IS-GRAPH-IRI: the value of ckp:adopts IS the graph IRI to compose.
-- No locator vocabulary is invented (a locator property would mint into core);
-- the convention already holds on the bench (urn:ckp:module/{wave,lexicon}/v3.11).
--
-- The adoption query runs over ckp.instances BODIES — possible only since #59
-- persisted the stamped body, which is a pleasing dependency: adoption-derived
-- composition stands on durable seals, not on transient gate state.
--
-- Fail-closed at the reference: an adopted graph that does not exist or is
-- EMPTY raises — a missing module must never silently narrow the enforcement
-- surface (shapes vanishing from the gate is silent un-enforcement, the defect
-- class this whole line exists to end). The regression floor holds by
-- construction: with zero Adoptions sealed the union is core ∪ kernel exactly
-- as before, byte-identical.
--
-- Supersession: an Adoption is out of force when a sealed ckp:Supersession
-- names it (ckp:supersedes = the adoption's @id). Withdrawal is a sealed act,
-- never a DELETE (§6 of the persona spec; S5: fence, never erase).
--
-- B2. The completeness floor runs only at CREATE EXTENSION, so every database
-- reached by ALTER EXTENSION UPDATE still had PUBLIC EXECUTE on 13 functions
-- including boot, import_module, load_kernel and bootstrap_kernel (proacl NULL —
-- never revoked; measured 2026-08-10, PASS-25 d-25-pgck-5). The revoke +
-- re-pin now runs on the upgrade route too.

CREATE OR REPLACE FUNCTION ckp._adopted_graphs(p_project text)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
BEGIN
  -- Sealed, unsuperseded Adoptions of THIS project, in seal order. intoProject
  -- accepts both the bare project urn and the /kernel/ck form (the kernel IS
  -- the project's governed identity; both spellings appear in early seals).
  RETURN COALESCE((
    SELECT array_agg(a.body->>(N||'adopts') ORDER BY a.ts_created)
    FROM ckp.instances a
    WHERE a.body->>'type' = N||'Adoption'
      AND a.body->>(N||'adopts') IS NOT NULL
      AND a.body->>(N||'intoProject') IN ('urn:ckp:'||p_project, 'urn:ckp:'||p_project||'/kernel/ck')
      AND NOT EXISTS (
        SELECT 1 FROM ckp.instances s
        WHERE s.body->>'type' = N||'Supersession'
          AND s.body->>(N||'supersedes') = a.body->>'@id')
  ), ARRAY[]::text[]);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text DEFAULT 'demo'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_core int; v_kernel int; v_comp int; v_mod int;
  v_iri  text;
  v_cnt  int;
BEGIN
  v_core   := pgrdf.add_graph('urn:ckp:core');
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  v_comp   := pgrdf.add_graph(format('urn:ckp:%s/shapes/composed', p_project));
  PERFORM pgrdf.clear_graph(v_comp);
  PERFORM pgrdf.copy_graph(v_core,   v_comp);
  PERFORM pgrdf.copy_graph(v_kernel, v_comp);
  -- A2: every graph a sealed unsuperseded Adoption names joins the surface.
  -- Module-IRI-is-graph-IRI: the adopts value IS the graph. Fail CLOSED on a
  -- dangling or empty reference — a vanished module silently narrowing the
  -- gate is un-enforcement nobody would see.
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(p_project) LOOP
    v_mod := pgrdf.add_graph(v_iri);
    SELECT count(*) INTO v_cnt
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } } LIMIT 1', v_iri));
    IF v_cnt = 0 THEN
      RAISE EXCEPTION 'ckp._composed_shapes: adopted module graph % is absent or empty — a sealed Adoption names it, so composing without it would silently narrow the enforcement surface. Load the module graph or seal a Supersession.', v_iri;
    END IF;
    PERFORM pgrdf.copy_graph(v_mod, v_comp);
  END LOOP;
  -- Entailment is per-graph and pgrdf.validate does not entail, so the closure
  -- is computed HERE, once, rather than depended on at validate time.
  PERFORM pgrdf.materialize(v_comp);
  RETURN v_comp;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- B2: the ring floor, on the upgrade route. Same statements the completeness
-- pass runs at install — an upgraded catalog must equal a fresh one.
-- ---------------------------------------------------------------------------
DO $floor_0435$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT pr.oid, pr.prokind FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.prokind IN ('f','p')
  LOOP
    IF p.prokind = 'f' THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    ELSE
      EXECUTE format('ALTER PROCEDURE %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER PROCEDURE %s SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    END IF;
  END LOOP;
END
$floor_0435$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM ck_participant;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
DO $door_0435$
DECLARE p record;
BEGIN
  -- every ckp.dispatch overload is the door; everything else stays closed.
  FOR p IN
    SELECT pr.oid
    FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.proname = 'dispatch' AND pr.prokind = 'f'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ck_participant', p.oid::regprocedure);
  END LOOP;
END
$door_0435$;

CREATE OR REPLACE PROCEDURE ckp._enforce_internal_floor()
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
BEGIN
  -- Single idempotent statement set: applies to EVERY table/sequence currently in
  -- schema ckp (config + dictionary now; instances/ledger/proof/outbox after
  -- bootstrap; plans after CI-C-4). No PUBLIC; ck_substrate is the operating role.
  REVOKE ALL ON ALL TABLES    IN SCHEMA ckp FROM PUBLIC;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA ckp FROM PUBLIC;
  GRANT  ALL ON ALL TABLES    IN SCHEMA ckp TO ck_substrate;
  GRANT  ALL ON ALL SEQUENCES IN SCHEMA ckp TO ck_substrate;
  -- Schema USAGE for the operating roles (measured missing from zero,
  -- 2026-08-08): the ring-1 definer set runs as ck_substrate and resolves
  -- ckp.* by name, and the outbox drain connects as ck_drainer — without
  -- USAGE both die on a FRESH install ('permission denied for schema ckp')
  -- while every long-lived bench works, because its grants predate the
  -- completeness file. The completeness pass grants ckp USAGE to
  -- ck_participant only; these two were only ever granted by hand.
  GRANT  USAGE ON SCHEMA ckp TO ck_substrate;
  GRANT  USAGE ON SCHEMA ckp TO ck_drainer;
  -- PROCEDURES (measured 2026-08-10, B2): 'ALL FUNCTIONS' does not cover
  -- procedures, so boot/import_module/load_kernel/bootstrap_kernel kept
  -- default PUBLIC EXECUTE on every route — mitigated only accidentally by
  -- their pg_read_file superuser gate. Revoke PUBLIC (explicit role grants
  -- survive a PUBLIC revoke untouched); ck_substrate keeps EXECUTE.
  REVOKE ALL ON ALL PROCEDURES IN SCHEMA ckp FROM PUBLIC;
  REVOKE ALL ON ALL PROCEDURES IN SCHEMA ckp FROM ck_participant;
  GRANT  EXECUTE ON ALL PROCEDURES IN SCHEMA ckp TO ck_substrate;
END;
$procedure$
;

CALL ckp._enforce_internal_floor();
