-- pgck 0.4.90 -> 0.4.91
--
-- BUILD ON THE ENGINE RATHER THAN BESIDE IT. pgRDF v0.6.34 shipped a set of
-- instruments this substrate had been doing without, or duplicating. Their LIB
-- spec closes with the brief: "the law arrives pre-typed — the screen's honesty is
-- a rendering job, not a reconstruction job. That was the whole point of the
-- E-series: build on it." This release does.
--
-- B1 DELEGATION (FINAL-HANDOVER). ckp._structural_digest carried a second
-- implementation of an algorithm the engine now owns as pgrdf.structural_digest()
-- — pgrdf-fd1-sha256, byte-for-byte the same. Two implementations of a digest is
-- a pure divergence risk: the day they drift, every structural pin in this ledger
-- silently means something the engine disagrees with, and NOTHING reports it.
--
-- Gated on a MEASUREMENT, not a version number. Verified 2026-09-01 on ckdev
-- against three graphs of different shape (urn:ckp:core 47d24485…,
-- urn:ckp:module:wave 97f1066f…, urn:ckp:pgck/kernel/ck 8788ee64…) — identical on
-- all three. The local body is RETAINED as a fallback so an older engine still
-- answers rather than refusing, and s79 asserts the two agree wherever both
-- exist: a delegation nothing can falsify is an act of faith, not engineering.
--
-- ckp.digests(g) — BOTH PLANES, EACH CARRYING ITS METHOD. fd1 equality is
-- ISOMORPHIC_LIKELY (symmetric blank-node structures collide; the engine's own
-- witness is a 4-cycle vs two 2-cycles); RDFC-1.0 equality is PROOF. Additive by
-- construction: nothing sealed changes meaning, because redefining what
-- surfaceDigest means would silently reinterpret every pin ever sealed. The
-- method label is never optional — a digest whose method is not stated is not a
-- pin, it is a number that looks like one.
--
-- ckp.storage() — the other half of ε0 honesty, deferred from 0.4.89 so a
-- correctness fix would not drag an engine dependency with it. Adopts pgRDF's
-- freshness vocabulary (current | stale | never | unknown) rather than minting
-- ours, because they already enforce "state is not health" one layer down.
-- Measured motivation, ckdev: 60 MB / 38 graphs / 148 partitions ≈ 1.58 MB per
-- graph, so a self-service germination costs ~3.2 MB before anything is sealed
-- into it — and 4 of 38 graphs were validate-scratch leftovers. That ratio
-- matters more than the bytes: put validation on a recurring schedule and the
-- CLOCK becomes the leak, growth tracking time elapsed rather than work done.
--
-- ckp._engine_completeness() — pgRDF asked for this directly: "since ckp.dispatch
-- executes pgrdf reads via SPI in the same backend, the substrate can attach the
-- verdict to every read envelope server-side." It closes a blind spot
-- _read_verdict cannot see: that function counts ROWS, and this engine's
-- characteristic failure is an answer that is SHORT, not wrong — paths truncate
-- and filter clauses drop INSIDE the engine, so a read returning 10 of 10 is
-- `complete` by our count and may still have been narrowed.
--
-- ⚠ NOT attached automatically, and the reason is the point. last_call_stats() is
-- SESSION-LOCAL and per-call. Sprayed onto a read that ran no SPARQL it would
-- report some other query's numbers as if they were this one's — a confident
-- wrong answer, the exact defect class this substrate exists to retire. It is
-- opt-in for the call sites that actually touch the engine; everything else says
-- `unreported`, which is a state and explicitly not a claim of completeness.
--
-- Negative control: sql/test/s79_engine_surface_adopted.sql — delegation
-- agreement, the two planes proven DISTINCT (or (a) would pass while proving
-- nothing), method labels mandatory, storage as state, completeness measured or
-- declared absent.

CREATE OR REPLACE FUNCTION ckp._structural_digest(p_graph bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- 0.4.67 — THE STRUCTURAL PLANE (§5b alignment, finding-1786862028710113000).
--
-- _surface_digest is the COPY plane: sha256 over rendered lines with blank-node
-- LABELS included, so it moves on every reload and no third party can recompute
-- it from published files. This is the plane that survives: each blank node is
-- replaced by a signature over its own incident triples (itself marked _:a,
-- every other blank node flattened to _:z), so the digest depends on the shape
-- a node sits in and never on the label it happened to receive.
--
-- THE ALGORITHM IS THE FLEET'S, byte-for-byte — method label pgrdf-fd1-sha256,
-- owned by the engine since pgRDF v0.6.34 as pgrdf.structural_digest(). (An
-- earlier revision of this comment cited "pgrdf_fingerprint", a function that
-- existed in no schema — the exact folklore-citation class pgRDF's L7 measured;
-- corrected 2026-08-26. Delegating this body to the engine is FINAL-HANDOVER B1.)
--   ground     = sorted lines with no blank node, joined by \n, sha256
--   sig(b)     = sha256 of b's incident lines (self→_:a, other→_:z), sorted
--   bnode      = sha256 of the sorted signature hexes, joined by \n
--   structural = sha256( ground_text || '\n--\n' || signature_hexes )
-- ACCEPTANCE, measured 2026-08-16: three independent loads of the v3.11 core
-- (bench urn:ckp:core, bench urn:ckp:core/v3.11, test-rig urn:ckp:core) carry
-- three different byte digests and ONE structural digest, 9a791c6c3d6d07cb… —
-- reproduced by this function against the client-side tool's published pins.
--
-- HONEST LIMITS, never to be flattened: this is FIRST-DEGREE hashing, not
-- RDFC-1.0 — equal digests are strong evidence of isomorphism, NOT proof
-- (symmetric blank-node structures can collide); unequal digests ARE proof of
-- difference. ASSERTED ONLY — inferred triples re-derive and are a check
-- value, never content.
--
-- INTERIM SEAT: reads the engine's quad/dictionary tables directly because the
-- public SPARQL surface cannot exclude inferred triples. The coupling is pinned
-- by the co-shipped bundle and fails LOUD on schema drift; pgRDF#117
-- (pgrdf.graph_digest, RDFC-1.0) retires this function's body.
DECLARE
  v_ground text;
  v_sigs   text;
BEGIN
  -- 0.4.91 — DELEGATE (FINAL-HANDOVER B1). pgRDF v0.6.34 ships this exact
  -- algorithm as pgrdf.structural_digest(), method label pgrdf-fd1-sha256, owned
  -- by the engine that owns the graphs. Keeping a second implementation of a
  -- digest is a pure divergence risk with no upside: the day the two drift, every
  -- structural pin in this ledger silently means something different from what
  -- the engine says, and NOTHING would report it.
  --
  -- Delegation is gated on a MEASUREMENT, not on a version number. Verified
  -- 2026-09-01 on ckdev, three graphs of different shape:
  --   urn:ckp:core            47d24485627e459f… identical
  --   urn:ckp:module:wave     97f1066fc04460bb… identical
  --   urn:ckp:pgck/kernel/ck  8788ee647b5f2e4c… identical
  -- Byte-for-byte on all three. The local body is RETAINED, not deleted, so an
  -- engine without the function still answers rather than refusing — and so this
  -- delegation stays falsifiable: s79 asserts the two agree wherever both exist,
  -- which is a check that can actually fail if the engine ever changes.
  IF to_regprocedure('pgrdf.structural_digest(bigint)') IS NOT NULL THEN
    RETURN pgrdf.structural_digest(p_graph);
  END IF;

  IF to_regclass('pgrdf._pgrdf_quads') IS NULL OR to_regclass('pgrdf._pgrdf_dictionary') IS NULL THEN
    RAISE EXCEPTION 'ckp._structural_digest: the engine''s quad/dictionary tables are not where the pinned bundle put them — refusing rather than inventing a digest (interim seat; pgRDF#117 is the lasting one)';
  END IF;
  WITH t AS (
    SELECT x.subject_id sid, x.object_id oid, s.term_type st, o.term_type ot,
      CASE s.term_type WHEN 1 THEN '<'||s.lexical_value||'>' WHEN 2 THEN '_:'||s.lexical_value
        ELSE '"'||replace(replace(s.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"')||'"' END AS sr,
      CASE p.term_type WHEN 1 THEN '<'||p.lexical_value||'>' WHEN 2 THEN '_:'||p.lexical_value
        ELSE '"'||replace(replace(p.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"')||'"' END AS pr,
      CASE o.term_type WHEN 1 THEN '<'||o.lexical_value||'>' WHEN 2 THEN '_:'||o.lexical_value
        ELSE '"'||replace(replace(replace(o.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"'), chr(10), chr(92)||'n')||'"'
          || coalesce('@'||o.language_tag,
               CASE WHEN dt.lexical_value IS NOT NULL AND dt.lexical_value <> 'http://www.w3.org/2001/XMLSchema#string'
                    THEN '^^<'||dt.lexical_value||'>' END, '') END AS orr
    FROM pgrdf._pgrdf_quads x
    JOIN pgrdf._pgrdf_dictionary s ON s.id = x.subject_id
    JOIN pgrdf._pgrdf_dictionary p ON p.id = x.predicate_id
    JOIN pgrdf._pgrdf_dictionary o ON o.id = x.object_id
    LEFT JOIN pgrdf._pgrdf_dictionary dt ON dt.id = o.datatype_iri_id
    WHERE x.graph_id = p_graph AND NOT x.is_inferred
  ),
  ground AS (
    SELECT string_agg(sr||' '||pr||' '||orr||' .', E'\n' ORDER BY (sr||' '||pr||' '||orr||' .') COLLATE "C") AS g
    FROM t WHERE st <> 2 AND ot <> 2
  ),
  bnodes AS (
    SELECT DISTINCT sid AS b FROM t WHERE st = 2
    UNION SELECT DISTINCT oid FROM t WHERE ot = 2
  ),
  incident AS (
    SELECT b.b,
      CASE WHEN t.st=2 THEN CASE WHEN t.sid=b.b THEN '_:a' ELSE '_:z' END ELSE t.sr END
      ||' '||t.pr||' '||
      CASE WHEN t.ot=2 THEN CASE WHEN t.oid=b.b THEN '_:a' ELSE '_:z' END ELSE t.orr END
      ||' .' AS nline
    FROM bnodes b JOIN t ON (t.st=2 AND t.sid=b.b) OR (t.ot=2 AND t.oid=b.b)
  ),
  sigs AS (
    SELECT encode(digest(convert_to(string_agg(nline, E'\n' ORDER BY nline COLLATE "C"),'UTF8'),'sha256'),'hex') AS sig
    FROM incident GROUP BY b
  )
  SELECT COALESCE((SELECT g FROM ground), ''),
         COALESCE((SELECT string_agg(sig, E'\n' ORDER BY sig COLLATE "C") FROM sigs), '')
    INTO v_ground, v_sigs;
  RETURN encode(digest(convert_to(v_ground||E'\n--\n'||v_sigs, 'UTF8'), 'sha256'), 'hex');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._engine_completeness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v jsonb; v_trunc int; v_drop int;
BEGIN
  IF to_regprocedure('pgrdf.last_call_stats()') IS NULL THEN
    RETURN jsonb_build_object('engine', jsonb_build_object(
      'verdict', 'unreported',
      'note', 'this engine predates pgrdf.last_call_stats() — UNREPORTED is a state, not a fault, and not a claim of completeness'));
  END IF;
  SELECT pgrdf.last_call_stats() INTO v;
  v_trunc := COALESCE((v->>'path_depth_truncations')::int, 0);
  v_drop  := COALESCE((v->>'filter_clauses_dropped')::int, 0);
  RETURN jsonb_build_object('engine', jsonb_build_object(
    'verdict', CASE WHEN v_trunc > 0 OR v_drop > 0 THEN 'short' ELSE 'complete' END,
    'pathDepthTruncations', v_trunc,
    'filterClausesDropped', v_drop,
    'method', 'pgrdf.last_call_stats — session-local, describes THIS backend''s most recent query verb',
    'note', CASE WHEN v_trunc > 0 OR v_drop > 0
      THEN 'SHORT: the engine narrowed this answer. The rows returned are correct; the set is incomplete, and a row count alone would not have shown it.'
      ELSE 'complete: the engine truncated no path and dropped no filter clause for this call.' END));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.digests(p_graph bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v jsonb;
BEGIN
  v := jsonb_build_object(
    'structural', jsonb_build_object(
      'value',  ckp._structural_digest(p_graph),
      'method', 'pgrdf-fd1-sha256',
      'equalMeans', 'ISOMORPHIC_LIKELY — evidence, not proof; UNEQUAL is conclusive'));
  IF to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL THEN
    v := v || jsonb_build_object('canonical', jsonb_build_object(
      'value',  pgrdf.graph_digest(p_graph),
      'method', 'rdfc-1.0-sha256',
      'equalMeans', 'PROOF of isomorphism'));
  ELSE
    v := v || jsonb_build_object('canonical', jsonb_build_object(
      'value', NULL, 'method', NULL,
      'equalMeans', 'unavailable — this engine predates pgrdf.graph_digest(); the conclusive plane is a state, not a fault'));
  END IF;
  RETURN v || jsonb_build_object(
    'note', 'the two planes are NEVER comparable with each other. Render the method beside '
            'every value; a digest whose method is not stated is not a pin.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.storage()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_fresh jsonb; v_orph int; v_scratch int; v_graphs int;
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

  RETURN jsonb_build_object(
    'available', true,
    'bytes', pg_database_size(current_database()),
    'pretty', pg_size_pretty(pg_database_size(current_database())),
    'graphs', COALESCE(v_graphs,0),
    'materialization', COALESCE(v_fresh,'{}'::jsonb),
    'orphanPartitions', v_orph,
    'scratchGraphs', v_scratch,
    'note', 'materialization states are pgRDF''s vocabulary, adopted rather than re-minted: '
            '`never` and `unknown` are STATES, only `stale` is a warning, and orphanPartitions '
            'warns only when non-zero. scratchGraphs counts validation leftovers — if that '
            'number grows without validations being run, a schedule is leaking, not a user.');
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
    'findings', v_find,
    'note', CASE v_state
      WHEN 'core-only'  THEN 'no kernel named: the law is loaded and readable, sealing refuses on M2. A complete state, not a fault.'
      WHEN 'named'      THEN 'a project resolves but no ckp:Kernel is sealed — germination is the open next act.'
      ELSE 'a ckp:Kernel is sealed for this project.' END,
    'healthy', jsonb_array_length(v_find) = 0);
END;
$function$
;
