-- pgck 0.4.102 -> 0.4.103
--
-- C-12 · storage is reported PER KERNEL — a busy kernel is distinguishable
--        from a bad one.
-- C-17 · the identity triple, as a verb — version/build_id/extversion
--        together, and agreement is REFUSED where it cannot be shown.
--
-- C-12: the data was always attributable — every kernel-owned graph is
-- prefixed urn:ckp:<kernel>/ — the gap was a report, not a mechanism.
-- ckp.storage() now carries perKernel: {<kernel>: {graphs, asserted, bytes}},
-- with bytes read from the engine's per-graph partitions where present.
-- Graphs with no kernel prefix (core, modules, the empty default, validation
-- scratch) land in a NAMED 'substrate' bucket, never silently in somebody's
-- column: mis-attributing shared weight to a kernel would manufacture exactly
-- the busy-vs-bad confusion this closes.
--
-- C-17: pgRDF's own statement — a stale .so and a pre-tag artifact have both
-- been caught ONLY by version() == build_id() == extversion — and this fleet
-- measured the pgCK version of that failure: two live benches reporting ONE
-- identical build identifier while running TWO different binaries. The
-- neighbouring layer named the defect class and shipped the instrument; now
-- this layer has it. ckp.identity_triple() reads each plane defensively (an
-- unreadable plane is NULL, never a guess) and hands the verdict to a PURE
-- comparator, ckp._identity_agreement(version, extversion, build_id) — one
-- rule, two callers, so the probe that proves detection feeds the comparator
-- a mismatched pair and the live verb cannot have a private copy. Agreement
-- is never fabricated: NULL in, verdict 'unmeasurable' out. Divergence names
-- both planes and the cure, and the cure is the standing doctrine: report the
-- divergence; never restart to hide it.
--
-- Both surface through the door: surface.check now carries 'engineIdentity'
-- beside 'roster' and 'storage', at both call sites.
--
-- Controls: sql/test/s83_identity_and_attribution.sql (wired into smoke-s4);
-- TDD C-12 and C-17 upgraded from existence stubs to behaviour probes and
-- flip GREEN here.

CREATE OR REPLACE FUNCTION ckp.storage()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_fresh jsonb; v_orph int; v_scratch int; v_graphs int; v_perk jsonb;
BEGIN
  IF to_regprocedure('pgrdf.graph_inventory()') IS NULL THEN
    RETURN jsonb_build_object(
      'available', false,
      'note', 'pgrdf.graph_inventory() is absent — this engine predates v0.6.34. Storage is UNREPORTED, which is a state, not a fault.');
  END IF;

  SELECT jsonb_object_agg(m, c), sum(c) INTO v_fresh, v_graphs
    FROM (SELECT COALESCE(materialization,'unknown') m, count(*) c FROM pgrdf.graph_inventory() GROUP BY 1) t;

  SELECT count(*) INTO v_orph FROM pgrdf.orphan_partitions();
  SELECT count(*) INTO v_scratch FROM pgrdf.graph_inventory() WHERE iri LIKE 'urn:ckp:validate-scratch%';

  -- 0.4.103 (C-12) — STORAGE IS REPORTED PER KERNEL, so a busy kernel is
  -- distinguishable from a bad one. The data was always attributable — every
  -- kernel-owned graph is prefixed urn:ckp:<kernel>/ — the gap was a report,
  -- not a mechanism. Graphs with no kernel prefix (core, modules, the empty
  -- default, validation scratch) land in the 'substrate' bucket BY NAME, never
  -- silently in somebody's column: mis-attributing shared weight to a kernel
  -- would manufacture exactly the busy-vs-bad confusion this closes. Bytes are
  -- the engine's per-graph partitions where present (pg_total_relation_size of
  -- _pgrdf_quads_g<id>), and absence of a partition is 0, not an error.
  SELECT jsonb_object_agg(k, jsonb_build_object('graphs', gs, 'asserted', a, 'bytes', b))
    INTO v_perk
    FROM (SELECT COALESCE(substring(g.iri from '^urn:ckp:([a-z0-9-]+)/'), 'substrate') k,
                 count(*) gs,
                 COALESCE(sum(inv.asserted),0) a,
                 COALESCE(sum(CASE WHEN to_regclass('pgrdf._pgrdf_quads_g'||g.graph_id) IS NOT NULL
                                   THEN pg_total_relation_size('pgrdf._pgrdf_quads_g'||g.graph_id)
                                   ELSE 0 END),0) b
            FROM pgrdf._pgrdf_graphs g
            LEFT JOIN pgrdf.graph_inventory() inv ON inv.iri = g.iri
           GROUP BY 1) t;

  RETURN jsonb_build_object(
    'available', true,
    'bytes', pg_database_size(current_database()),
    'pretty', pg_size_pretty(pg_database_size(current_database())),
    'graphs', COALESCE(v_graphs,0),
    'materialization', COALESCE(v_fresh,'{}'::jsonb),
    'perKernel', COALESCE(v_perk,'{}'::jsonb),
    'orphanPartitions', v_orph,
    'scratchGraphs', v_scratch,
    'note', 'materialization states are pgRDF''s vocabulary, adopted rather than re-minted: '
            '`never` and `unknown` are STATES, only `stale` is a warning, and orphanPartitions '
            'warns only when non-zero. scratchGraphs counts validation leftovers — if that '
            'number grows without validations being run, a schedule is leaking, not a user.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._identity_agreement(p_version text, p_extversion text, p_build_id text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  -- 0.4.103 (C-17) — the comparator, PURE, so the probe that proves detection
  -- feeds it a mismatched pair and the live verb cannot have a private copy:
  -- one rule, two callers (§2 — a probe that re-implements the gate tests the
  -- probe). Agreement is NEVER fabricated: a NULL input yields agreement NULL
  -- ('unmeasurable'), not true — the verb refuses agreement it cannot show.
  SELECT CASE
    WHEN p_version IS NULL OR p_extversion IS NULL THEN
      jsonb_build_object('agreement', NULL, 'state', 'unmeasurable',
        'hint', 'one plane is unreadable — refusing to claim agreement that cannot be shown')
    WHEN p_version = p_extversion THEN
      jsonb_build_object('agreement', true, 'state', 'agree')
    ELSE
      jsonb_build_object('agreement', false, 'state', 'diverged',
        'divergence', jsonb_build_object('version', p_version, 'extversion', p_extversion,
                                         'build_id', p_build_id),
        'hint', 'version() is the LOADED .so and extversion is the SQL catalog: they diverge '
                'when a new .so awaits a postmaster restart, or when ALTER EXTENSION UPDATE '
                'ran ahead of the artifact. Report the divergence; never restart to hide it.')
  END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.identity_triple()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_ver text; v_ext text; v_bld text;
BEGIN
  -- 0.4.103 (C-17) — THE IDENTITY TRIPLE, AS A VERB. pgRDF's own statement: a
  -- stale .so and a pre-tag artifact have both been caught ONLY by
  -- version() == build_id() == extversion — and this fleet measured the pgCK
  -- version of that failure: two live benches reporting one identical build
  -- identifier while running two different binaries. The neighbouring layer
  -- named the defect class and shipped the instrument; now this layer has it.
  -- Each plane is read defensively: an unreadable plane reports NULL and the
  -- comparator refuses agreement — three strings and a shrug would be worse
  -- than no verb at all.
  BEGIN v_ver := ckp.version();  EXCEPTION WHEN OTHERS THEN v_ver := NULL; END;
  BEGIN v_bld := ckp.build_id(); EXCEPTION WHEN OTHERS THEN v_bld := NULL; END;
  SELECT extversion INTO v_ext FROM pg_extension WHERE extname = 'pgck';
  RETURN jsonb_build_object('version', v_ver, 'extversion', v_ext, 'build_id', v_bld)
         || ckp._identity_agreement(v_ver, v_ext, v_bld);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_check(p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj   text := COALESCE(p_project, ckp._project());
  v_kiri   text;
  v_epoch  int;
  v_ep_iri text;
  v_pin_surf text;
  v_pin_src  text;
  v_comp   int;
  v_act_surf text;
  v_act_src  text;
  v_kquads int;
  v_shapes int;
  v_mods   jsonb := '[]'::jsonb;
  v_iri    text;
  v_n      int;
  v_find   jsonb := '[]'::jsonb;
  v_state  text;
BEGIN
  -- 0.4.81 — CORE-ONLY SHORT-CIRCUIT. With no kernel named there is no kernel
  -- graph to name, and building 'urn:ckp:'||NULL||'/kernel/ck' produced a NULL
  -- IRI that reached pgrdf.sparql as a parse error — the check crashed on
  -- exactly the state it was taught to call healthy. (Caught by s72, which is
  -- the argument for writing the gate with the change rather than after it.)
  IF v_proj IS NULL THEN
    v_comp := ckp._composed_shapes(NULL);          -- the surface IS core
    RETURN jsonb_build_object(
      'ok', true, 'kernel', NULL, 'state', 'core-only', 'epoch', 0,
      'epoch_resource', NULL,
      'surface', jsonb_build_object('pinned', NULL, 'actual', ckp._surface_digest(v_comp), 'match', NULL),
      'source',  jsonb_build_object('pinned', NULL, 'actual', NULL, 'match', NULL),
      'kernel_graph', NULL,
      'composed_nodeshapes', (SELECT count(*) FROM pgrdf.sparql(format(
         'PREFIX sh: <http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <%s> { ?s a sh:NodeShape } }',
         pgrdf.graph_iri(v_comp)))),
      'modules', '[]'::jsonb,
      'roster', ckp.roster(),          -- 0.4.90 Q-1
      'storage', ckp.storage(),        -- 0.4.91
      'engineIdentity', ckp.identity_triple(),   -- 0.4.103 C-17
      'findings', '[]'::jsonb,
      'note', 'no kernel named: the law is loaded and readable (surface.declared, surface.typecheck, instance.validate all answer), and sealing refuses on M2. A complete state, not a fault.',
      'healthy', true);
  END IF;

  v_kiri  := 'urn:ckp:'||v_proj||'/kernel/ck';
  v_epoch := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);

  -- What the ledger says the surface was, at the epoch in force.
  SELECT i.body->>'@id', i.body->>(N||'surfaceDigest')
    INTO v_ep_iri, v_pin_surf
  FROM ckp.instances i
  WHERE i.body->>'type' = N||'Epoch'
    AND i.body->>(N||'producedBy') = v_kiri
    AND (i.body->>(N||'epoch'))::int = v_epoch
  ORDER BY i.ts_created DESC LIMIT 1;

  SELECT i.body->>(N||'sourceDigest') INTO v_pin_src
  FROM ckp.instances i
  WHERE i.body->>'type' = N||'Materialization'
    AND i.body->>(N||'producesEpoch') = v_ep_iri
  ORDER BY i.ts_created DESC LIMIT 1;

  -- What it is now.
  v_comp     := ckp._composed_shapes(v_proj);
  v_act_surf := ckp._surface_digest(v_comp);
  v_act_src  := ckp._surface_digest(pgrdf.add_graph(v_kiri));

  SELECT count(*) INTO v_kquads
    FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } }', v_kiri));
  SELECT count(*) INTO v_shapes
    FROM pgrdf.sparql(format('PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <%s> { ?s a sh:NodeShape } }',
                             (SELECT iri FROM pgrdf._pgrdf_graphs WHERE graph_id = v_comp)));

  -- Every adopted module: present and non-empty, or named as missing.
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(v_proj) LOOP
    SELECT count(*) INTO v_n
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } }', v_iri));
    v_mods := v_mods || jsonb_build_array(jsonb_build_object('iri', v_iri, 'quads', v_n, 'present', v_n > 0));
    IF v_n = 0 THEN
      v_find := v_find || jsonb_build_array('adopted module is ABSENT or EMPTY: '||v_iri);
    END IF;
  END LOOP;

  -- Findings. Each names what was measured, never a guess at the cause.
  -- 0.4.81 — STATE IS NOT HEALTH, and an empty kernel graph means different
  -- things in each state. A brand-new install reported `healthy:false` with a
  -- "wipe signature" on a machine where nothing had ever happened: the check
  -- could not tell NEVER EXISTED from WAS DESTROYED, and a diagnostic that is
  -- false on every correct day-one install is the twin of one that can never
  -- fail — nobody trusts it, so it cannot do its job.
  --
  --   core-only   no kernel named. The surface IS core. Complete and correct:
  --               the law is readable, sealing refuses on M2. NOT a fault.
  --   named       a project resolves but no ckp:Kernel is sealed. Germination
  --               is the open next act.
  --   germinated  a Kernel is sealed. NOW an empty graph is a real wipe.
  IF v_proj IS NULL THEN
    v_state := 'core-only';
  ELSIF EXISTS (SELECT 1 FROM ckp.instances
                 WHERE body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Kernel'
                   AND body->>'@id'  = 'urn:ckp:'||v_proj||'/kernel') THEN
    v_state := 'germinated';
  ELSE
    v_state := 'named';
  END IF;

  IF v_kquads = 0 AND v_state = 'germinated' THEN
    v_find := v_find || jsonb_build_array(
      'kernel graph '||v_kiri||' is EMPTY while a ckp:Kernel IS sealed for this project — '||
      'the enforcement surface is composed WITHOUT the kernel''s own shapes. This is the '||
      '2026-08-10 wipe signature: something that existed is gone.');
  END IF;
  IF v_shapes = 0 THEN
    v_find := v_find || jsonb_build_array(
      'composed surface carries ZERO NodeShapes — every gate is vacuous; refuse to trust any conformance result');
  END IF;
  -- 0.4.89 — NEVER-PINNED IS NOT DRIFT, AND A FINDING IS NEVER NULL.
  -- 0.4.81 guarded the FIRST branch with `v_epoch > 0` and left the ELSIF
  -- unguarded, so the case it deliberately excluded fell straight through:
  -- with v_pin_surf NULL, `NULL IS DISTINCT FROM <digest>` is TRUE, the drift
  -- message concatenated `left(NULL,12)`, and in SQL one NULL operand makes
  -- the WHOLE string NULL. jsonb_build_array(NULL) is `[null]`, so a freshly
  -- germinated kernel at epoch 0 accused itself with a finding nobody could
  -- read. Two independent routes agree on this root cause: the mechanical
  -- trace above, and SPORE §5.3's measurement — "findings:[null] appears
  -- specifically in the NEVER-PINNED case, not generally."
  --
  -- The three states are now explicit and mutually exclusive, so no branch can
  -- be reached by falling out of another:
  --   never pinned, epoch 0   -> pre-governance. A STATE. Not a finding.
  --   never pinned, epoch > 0 -> a real fault: an apply advanced without sealing.
  --   pinned, and differs     -> real drift, both digests named.
  IF v_pin_surf IS NULL AND v_state = 'germinated' AND v_epoch > 0 THEN
    v_find := v_find || jsonb_build_array(format(
      'epoch %s is in force but no ckp:Epoch seals its digest — an apply advanced the epoch without recording the surface, so drift is undetectable',
      v_epoch));
  ELSIF v_pin_surf IS NOT NULL AND v_pin_surf IS DISTINCT FROM v_act_surf THEN
    -- format(), never `||`: format renders a NULL argument as the empty string,
    -- so a missing digest degrades the message rather than annihilating it.
    v_find := v_find || jsonb_build_array(format(
      'SURFACE DRIFT: the composed surface differs from the digest epoch %s sealed. '
      'Either the surface changed outside a governed apply (adoption, a direct graph write, or a wipe), '
      'or an apply failed to reseal. Pinned %s… actual %s…',
      v_epoch, left(v_pin_surf,12), COALESCE(left(v_act_surf,12),'(none)')));
  END IF;
  IF v_pin_src IS NOT NULL AND v_pin_src IS DISTINCT FROM v_act_src THEN
    v_find := v_find || jsonb_build_array(format(
      'SOURCE DRIFT: the kernel graph differs from the sourceDigest its Materialization sealed. '
      'Pinned %s… actual %s…',
      left(v_pin_src,12), COALESCE(left(v_act_src,12),'(none)')));
  END IF;

  -- 0.4.89 — THE FLOOR UNDER ALL OF THE ABOVE. Every finding is built by
  -- concatenation somewhere in this function and in integrity_check, and any
  -- NULL operand silently produces a JSON null. A check that reports a fault
  -- it cannot NAME is worse than no check: it is unfalsifiable by the reader.
  -- Rather than trust every call site forever, strip nulls here and, if one
  -- ever occurs, say so LOUDLY as a pgCK defect rather than as a substrate
  -- condition — the two must never be confused.
  IF v_find @> 'null'::jsonb THEN
    v_find := (SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                 FROM jsonb_array_elements(v_find) e
                WHERE jsonb_typeof(e) <> 'null')
              || jsonb_build_array(
                 'INTERNAL DEFECT (pgck): a finding was constructed NULL and has been '
                 'dropped. This is a bug in surface_check, NOT a condition of this '
                 'kernel. Report it — the substrate must never emit findings:[null].');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'kernel', v_proj,
    'state', v_state,
    'epoch', v_epoch,
    'epoch_resource', v_ep_iri,
    'surface', jsonb_build_object('pinned', v_pin_surf, 'actual', v_act_surf,
                                  'match', v_pin_surf IS NOT DISTINCT FROM v_act_surf),
    'source',  jsonb_build_object('pinned', v_pin_src,  'actual', v_act_src,
                                  'match', v_pin_src IS NOT DISTINCT FROM v_act_src),
    'kernel_graph', jsonb_build_object('iri', v_kiri, 'quads', v_kquads, 'empty', v_kquads = 0),
    'composed_nodeshapes', v_shapes,
    'modules', v_mods,
    'roster', ckp.roster(),            -- 0.4.90 Q-1
    'storage', ckp.storage(),          -- 0.4.91
    'engineIdentity', ckp.identity_triple(),     -- 0.4.103 C-17
    'findings', v_find,
    'note', CASE v_state
      WHEN 'core-only'  THEN 'no kernel named: the law is loaded and readable, sealing refuses on M2. A complete state, not a fault.'
      WHEN 'named'      THEN 'a project resolves but no ckp:Kernel is sealed — germination is the open next act.'
      ELSE 'a ckp:Kernel is sealed for this project.' END,
    'healthy', jsonb_array_length(v_find) = 0);
END;
$function$
;
