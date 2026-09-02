-- pgck 0.4.104 -> 0.4.105
--
-- C-14 · every routed verb has a sealed ckp:Affordance behind it — both
--        halves or neither (pgCK#56, the 37-wide gap, closed).
--
-- A registry row makes a verb CALLABLE; a sealed ckp:Affordance makes it a
-- FACT — attributed, gated by AffordanceShape, discoverable through the door.
-- Since 0.4.85 the governed registration path seals both halves in one act,
-- but the built-in routes never had declarations, so the gap only ever grew.
--
-- ckp.declare_routed_affordances() backfills every routed verb lacking its
-- seal, idempotently — and THE LAW DECIDED ITS DESIGN. The first draft sealed
-- built-ins with no derivedBy ("installed by the artifact") and the gate
-- refused every row naming the clause: AffordanceShape demands derivedBy
-- minCount 1, and MaterializationShape demands producesEpoch minCount 1. So
-- the backfill performs the full lawful act per kernel: the standing position
-- seals as a real ckp:Epoch where none exists (epoch unchanged — not an
-- advance; kernel_epoch.surface_digest written from the SAME variable, the
-- E-1 rule), one ckp:Materialization records the backfill (fromEpoch =
-- toEpoch, real digests, producesEpoch resolving), and each Affordance seals
-- derivedBy -> that Materialization. No producesAffordance list — a later
-- per-row failure would leave it citing a phantom, the sin adopts-resolves
-- refuses. Sealed plane is the root's closed vocabulary, routing 'query'
-- maps to 'derived' (0.4.85). Per-row failures are WARNED and returned,
-- never swallowed (0.4.92). Attribution: an unattributed session gets the
-- constant service identity svc:affordance-backfill (0.4.64 — never a fresh
-- uuid); a session with a verified requester keeps it.
--
-- ckp.boot() now runs the backfill after the core loads — pre-boot the gate
-- is fail-closed by design, so CREATE EXTENSION cannot do it. This migration
-- also runs it directly for already-booted databases; on a never-booted
-- database every row fails soft with a warning and the next boot completes
-- the act.
--
-- Any FUTURE migration that seeds new registry rows calls the backfill again
-- in the same act, or it regrows the gap this closed.
--
-- Controls: s85 (wired into smoke-s4); TDD C-14 upgraded to a PAIRWISE probe
-- that exercises the cure verb and asserts convergence and idempotence.

CREATE OR REPLACE FUNCTION ckp.declare_routed_affordances()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  r        record;
  k        record;
  v_prev   text := current_setting('ckp.project', true);
  v_prev_req text := current_setting('ckp.requester', true);
  v_sealed int := 0;
  v_failed jsonb := '[]'::jsonb;
  v_plane  text;
  v_epoch  int;
  v_comp   int;
  v_surfd  text;
  v_srcd   text;
  v_gid    bigint;
  v_eiri   text;
  v_miri   text;
BEGIN
  -- 0.4.105 (C-14) — BOTH HALVES OR NEITHER, RETROACTIVELY. A routed verb is a
  -- registry row; a declared capability is a sealed ckp:Affordance. The gap
  -- between them was 37 wide when first measured (pgCK#56) and grew with every
  -- version, because only the GOVERNED registration path (0.4.85) sealed its
  -- declaration. This backfills every routed verb that lacks its seal,
  -- idempotently — called at the end of ckp.boot() (pre-boot the gate is
  -- fail-closed, so CREATE EXTENSION cannot do it) and by the 0.4.105
  -- migration. Any future migration seeding new registry rows calls it again
  -- in the same act, or regrows the gap this closed.
  --
  -- THE LAW DECIDED THE DESIGN, against the first draft. AffordanceShape
  -- demands derivedBy minCount 1 — no underived affordance — and
  -- MaterializationShape demands producesEpoch minCount 1. The first draft
  -- sealed built-ins with NO derivedBy ("installed by the artifact") and the
  -- gate REFUSED every row, naming the clause: the law already rules that a
  -- declaration must cite the act that derived it. So the backfill performs
  -- the full lawful act, per kernel:
  --   * the kernel's standing position is sealed as a real ckp:Epoch where
  --     none exists — epoch unchanged (this is not an advance), surfaceDigest
  --     computed from the live composed surface, and the SAME variable is
  --     written to ckp.kernel_epoch (the E-1 shared-variable rule: the table
  --     cannot drift from the seal);
  --   * one ckp:Materialization records the backfill — fromEpoch = toEpoch =
  --     the standing epoch, real digests, producesEpoch citing the Epoch just
  --     sealed or already standing. No producesAffordance list: an Affordance
  --     that later failed its own seal would leave the list citing a phantom,
  --     which is the sin adopts-resolves refuses. The edge runs
  --     Affordance -> derivedBy -> Materialization only.
  --   * each Affordance seals with the registry row's truth: the sealed plane
  --     is the ROOT's closed vocabulary (routing 'query' maps to 'derived',
  --     the 0.4.85 rule; a routing value outside both vocabularies seals no
  --     plane rather than inventing one).
  -- A per-row failure is WARNED and returned, never swallowed (the 0.4.92
  -- reaper lesson), and never breaks boot.
  --
  -- Attribution: the seal refuses unattributed writes (0.4.64), and the
  -- sanctioned operator path is a declared SERVICE identity. A session that
  -- already carries a verified requester keeps it; only an unattributed
  -- session gets the constant service name — never a fresh uuid.
  IF COALESCE(NULLIF(trim(v_prev_req), ''), '') = '' THEN
    PERFORM set_config('ckp.requester', 'svc:affordance-backfill', true);
  END IF;

  -- ONLY GERMINATED KERNELS. A kernel with no kernel graph is not real here —
  -- it is a seed registry row (the substrate's own built-in verbs are
  -- attributed to 'pgck', which is germinated ONLY on a pgck bench, not on a
  -- demo/consumer rig). Declaring the capability of a kernel that does not
  -- exist would be premature, AND sealing its Epoch would compose its surface,
  -- which creates urn:ckp:<k>/kernel/ck at an AUTO id and steals the explicit
  -- kernel_graph_id slot the bootstrap load_kernel binds next (P0-A0) —
  -- measured: boot sealed for ungerminated pgck, then load_kernel(demo)
  -- refused 'graph_id 2 is bound to a different IRI'. Restricting to kernels
  -- WITH a kernel graph closes both issues: no premature declaration, and the
  -- only graphs composed are ones that already exist.
  FOR k IN SELECT DISTINCT ar.kernel FROM ckp.affordance_registry ar
            WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_graphs g
                           WHERE g.iri = format('urn:ckp:%s/kernel/ck', ar.kernel))
              AND NOT EXISTS (SELECT 1 FROM ckp.instances i
                               WHERE i.body->>'@id' = 'ckp://Affordance#'||ar.kernel||'.'||ar.verb
                                 AND i.body->>'type' = C||'Affordance')
            ORDER BY 1
  LOOP
    BEGIN
      PERFORM set_config('ckp.project', k.kernel, true);
      INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (k.kernel, 0) ON CONFLICT (kernel) DO NOTHING;
      SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = k.kernel;
      SELECT g.graph_id INTO v_gid FROM pgrdf._pgrdf_graphs g
       WHERE g.iri = format('urn:ckp:%s/kernel/ck', k.kernel);
      v_comp  := ckp._composed_shapes(k.kernel);
      v_srcd  := ckp._surface_digest(v_gid);
      v_surfd := ckp._surface_digest(v_comp);
      v_eiri  := format('urn:ckp:%s/epoch/%s', k.kernel, v_epoch);
      v_miri  := format('urn:ckp:%s/materialization/aff-backfill-%s', k.kernel, v_epoch);
      IF NOT EXISTS (SELECT 1 FROM ckp.instances i
                      WHERE i.body->>'@id' = v_eiri AND i.body->>'type' = C||'Epoch') THEN
        PERFORM ckp.seal('epoch-'||k.kernel||'-'||v_epoch, jsonb_build_object(
          'type', C||'Epoch', '@id', v_eiri,
          C||'epoch', to_jsonb(v_epoch),
          C||'surfaceDigest', v_surfd,
          C||'structuralDigest', ckp._structural_digest(v_comp)));
        UPDATE ckp.kernel_epoch SET surface_digest = v_surfd WHERE kernel = k.kernel;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM ckp.instances i
                      WHERE i.body->>'@id' = v_miri AND i.body->>'type' = C||'Materialization') THEN
        PERFORM ckp.seal('mat-'||k.kernel||'-aff-backfill-'||v_epoch, jsonb_build_object(
          'type', C||'Materialization', '@id', v_miri,
          C||'materializes', format('urn:ckp:%s/kernel/ck', k.kernel),
          C||'fromEpoch', to_jsonb(v_epoch),
          C||'toEpoch',   to_jsonb(v_epoch),
          C||'sourceDigest', v_srcd,
          C||'surfaceDigest', v_surfd,
          C||'producesEpoch', v_eiri));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed || jsonb_build_object('kernel', k.kernel, 'error', SQLERRM);
      RAISE WARNING 'ckp.declare_routed_affordances: could not seal the %s backfill materialization — %', k.kernel, SQLERRM;
      CONTINUE;
    END;

    FOR r IN SELECT * FROM ckp.affordance_registry ar
              WHERE ar.kernel = k.kernel
                AND NOT EXISTS (SELECT 1 FROM ckp.instances i
                                 WHERE i.body->>'@id' = 'ckp://Affordance#'||ar.kernel||'.'||ar.verb
                                   AND i.body->>'type' = C||'Affordance')
              ORDER BY ar.verb
    LOOP
      BEGIN
        v_plane := CASE WHEN r.plane = 'query' THEN 'derived'
                        WHEN r.plane IN ('instance','governance','derived') THEN r.plane
                        ELSE NULL END;
        PERFORM ckp.seal('aff-'||r.kernel||'-'||replace(r.verb,'.','-'),
          jsonb_build_object(
            'type', C||'Affordance',
            '@id',  'ckp://Affordance#'||r.kernel||'.'||r.verb,
            C||'inTopic', r.in_topic,
            C||'delegate', r.delegate,
            C||'derivedBy', v_miri)
          || CASE WHEN r.out_topic IS NOT NULL THEN jsonb_build_object(C||'outTopic', r.out_topic) ELSE '{}'::jsonb END
          || CASE WHEN v_plane IS NOT NULL THEN jsonb_build_object(C||'plane', v_plane) ELSE '{}'::jsonb END
          || CASE WHEN r.in_shape IS NOT NULL THEN jsonb_build_object(C||'inShape', r.in_shape) ELSE '{}'::jsonb END);
        v_sealed := v_sealed + 1;
      EXCEPTION WHEN OTHERS THEN
        v_failed := v_failed || jsonb_build_object('kernel', r.kernel, 'verb', r.verb, 'error', SQLERRM);
        RAISE WARNING 'ckp.declare_routed_affordances: could not seal %.% — %', r.kernel, r.verb, SQLERRM;
      END;
    END LOOP;
  END LOOP;
  PERFORM set_config('ckp.project', COALESCE(v_prev, ''), true);
  PERFORM set_config('ckp.requester', COALESCE(v_prev_req, ''), true);
  RETURN jsonb_build_object('ok', v_failed = '[]'::jsonb, 'sealed', v_sealed, 'failed', v_failed);
END;
$function$
;

CREATE OR REPLACE PROCEDURE ckp.boot(IN p_core_ttl_path text DEFAULT '/ontology/v3.12/core.ttl'::text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE v_core INT; v_ttl TEXT; v_shapes INT;
BEGIN
  PERFORM pgrdf.shmem_reset();
  -- P0-A0 (pgCK#23): resolve the core graph BY IRI and record the id it got.
  -- Never assume an id from config. Two paths bound graphs — one by explicit
  -- id from ckp.config, one by IRI with an auto-assigned id — and whichever ran
  -- first won the id. That left core_graph_id pointing at the kernel graph and
  -- boot raising 'graph_id 1 is bound to a different IRI' on every run, so the
  -- core ontology was never loaded and every ckp.validate(_, core) conformed
  -- trivially against an empty shapes graph.
  v_core := pgrdf.add_graph('urn:ckp:core');
  INSERT INTO ckp.config(k,v) VALUES ('core_graph_id', v_core::text)
    ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
  -- Fail loudly. An empty core graph is not a runnable state: it makes the
  -- seal's own ledger/proof gate unreachable and every core constraint inert.
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF v_shapes = 0 THEN
    RAISE EXCEPTION 'ckp.boot: core ontology at % loaded 0 sh:NodeShape — refusing to run with an unenforced core', p_core_ttl_path;
  END IF;
  -- Ring repair (fresh install, measured 2026-08-08): the per-graph tables
  -- this boot just created belong to the CALLING superuser — boot cannot be a
  -- ck_substrate definer because pg_read_file is superuser-gated — while every
  -- internal that reads them (ckp._composed_shapes and the rest of the ring-1
  -- definer set) runs as ck_substrate. On a fresh install the completeness
  -- floor ran at CREATE EXTENSION, before these tables existed, so the first
  -- seal died inside pgrdf.copy_graph with `permission denied for table
  -- _pgrdf_quads_g1`. Re-assert the substrate floor over pgrdf exactly as the
  -- completeness pass states it, now covering the dynamically created tables.
  -- (The lasting fix is a grant at creation inside pgrdf.add_graph — filed
  -- against pgRDF; this covers every graph boot itself creates.)
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
  -- 0.4.105 (C-14): the law is loaded, so every routed verb can now declare
  -- itself. Runs here rather than at CREATE EXTENSION because the seal's gate
  -- needs the core shapes this procedure just placed — pre-boot the gate is
  -- fail-closed by design (s34 measures it).
  PERFORM ckp.declare_routed_affordances();
  RAISE NOTICE 'ckp.boot: core graph % loaded from %, % NodeShapes', v_core, p_core_ttl_path, v_shapes;
END;
$procedure$
;

SELECT ckp.declare_routed_affordances();
