-- pgck 0.4.70 → 0.4.71 — pgRDF'S DELIVERABLES BROUGHT INTO USE
--
-- Four features the engine and its fleet shipped this pass stop being
-- documentation and start being consulted:
--
--   sh:closed          a shape can be LOCKED AND ENFORCED: add_class takes
--                      detail.closed + ignoredProperties, so an undeclared key
--                      REFUSES at the gate instead of minting into the type
--                      namespace. The default ignore list is the substrate
--                      envelope (rdf:type, four stamps, participant, board
--                      timestamps) — a closed shape that forgot them would
--                      refuse everything. Closing a FLEET type still demands
--                      governance care: enumerate its client envelope first.
--   pgRDF#118          adoption.check consults the loader's source_sha256 /
--                      source_loads (engine >= 0.6.31): the sealed Adoption's
--                      file-byte sourceDigest is COMPARED, not decorative —
--                      sourceDigestMatch false is a finding. Per-format
--                      boundary carried from pgRDF#120; older engines degrade
--                      honestly to the old reason.
--   I9 / R-11          the census verbs state their completeness: wave.signals
--                      declares itself INCOMPLETE with its measured blind
--                      spots enumerated; adoption.check names its verdict;
--                      both carry engine counters via ckp._engine_counters()
--                      (null → the reader must say UNKNOWN, never complete).
--   abort-poison fix   _dispatch_safe resets the engine term cache after any
--                      aborted dispatch (guarded, never eats the refusal) —
--                      a refused create no longer poisons the retry. Measured
--                      three times before promotion; s67 (5) is the control.
--
-- Changed: adoption_check, wave_signals, _op_to_ttl, _dispatch_safe.
-- New: _engine_counters.
CREATE OR REPLACE FUNCTION ckp._engine_counters()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v jsonb;
BEGIN
  BEGIN
    SELECT jsonb_build_object(
      'truncations', (pgrdf.stats()->>'path_depth_truncations')::bigint,
      'filtersDropped', (pgrdf.stats()->>'filter_clauses_dropped')::bigint)
    INTO v;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  RETURN v;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.adoption_check(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj text := ckp._project();
  v_iri  text;
  v_rows jsonb := '[]'::jsonb;
  v_pin  text; v_now text; v_drift boolean := false;
  -- 0.4.71 — pgRDF#118 CONSUMED: since engine 0.6.31 the loader records the
  -- exact input bytes' sha256 on _pgrdf_graphs (turtle funnel; staged/bulk/
  -- nquads do not yet — the boundary their PR states). When the column exists,
  -- the sealed Adoption's file-byte sourceDigest stops being decorative: it is
  -- COMPARED against what the loader measured. Guarded: on an older engine
  -- the fields read null and verifiable stays false with the old reason.
  v_has_src boolean := EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='pgrdf' AND table_name='_pgrdf_graphs' AND column_name='source_sha256');
  v_src text; v_loads int; v_sealed_src text;
BEGIN
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(v_proj) LOOP
    SELECT graph_digest INTO v_pin FROM ckp.adoption_pins WHERE graph_iri = v_iri;
    v_now := ckp._surface_digest(pgrdf.add_graph(v_iri));
    IF v_pin IS NOT NULL AND v_pin <> v_now THEN v_drift := true; END IF;
    v_src := NULL; v_loads := NULL;
    IF v_has_src THEN
      SELECT g.source_sha256, g.source_loads INTO v_src, v_loads
        FROM pgrdf._pgrdf_graphs g WHERE g.iri = v_iri;
    END IF;
    SELECT a.body->>(N||'sourceDigest') INTO v_sealed_src FROM ckp.instances a
      WHERE a.body->>'type' = N||'Adoption' AND a.body->>(N||'adopts') = v_iri
      ORDER BY a.ts_created DESC LIMIT 1;
    v_rows := v_rows || jsonb_build_object(
      'module', v_iri,
      'graphDigestNow', v_now,
      'graphDigestPinned', v_pin,
      'drifted', (v_pin IS NOT NULL AND v_pin <> v_now),
      -- 0.4.67: the structural plane, reported beside the copy plane. This is
      -- the value a party on ANOTHER store compares (finding-1786716790912211000:
      -- no consumer read path exposed a composed module's digest — this is that
      -- path, both planes, counts included). NULL structural pin = pinned
      -- before the structural plane existed; re-pins at next fresh composition.
      'structuralDigestNow', ckp._structural_digest(pgrdf.add_graph(v_iri)),
      'structuralDigestPinned', (SELECT p.structural_digest FROM ckp.adoption_pins p WHERE p.graph_iri = v_iri),
      'counts', (SELECT jsonb_build_object('nodeshapes', p.nodeshapes, 'properties', p.properties, 'asserted', p.asserted)
                   FROM ckp.adoption_pins p WHERE p.graph_iri = v_iri),
      'sourceDigest', (SELECT a.body->>(N||'sourceDigest') FROM ckp.instances a
                        WHERE a.body->>'type' = N||'Adoption'
                          AND a.body->>(N||'adopts') = v_iri
                        ORDER BY a.ts_created DESC LIMIT 1),
      'sourceRecorded',  v_src,
      'sourceLoads',     v_loads,
      'sourceDigestVerifiable', (v_src IS NOT NULL),
      'sourceDigestMatch', CASE WHEN v_src IS NULL OR v_sealed_src IS NULL THEN NULL
                                ELSE (v_src = v_sealed_src) END,
      'why', CASE WHEN v_src IS NOT NULL
        THEN 'the LOADER measured these bytes (pgRDF#118, engine >= 0.6.31): sourceRecorded is the sha256 of the exact input the parser consumed, sourceLoads > 1 self-reports that whole-graph byte identity no longer holds. sourceDigestMatch compares the sealed Adoption claim against the loader record — false is a finding, null means one side is absent. Coverage boundary per pgRDF#120: turtle funnel records; staged/bulk/nquads do not yet — an unrecorded graph on a new engine loaded by those paths reads null honestly.'
        ELSE 'sourceDigest is a FILE-BYTE sha256; a graph cannot recompute file bytes, and this engine does not record loader-side digests (pgRDF#118 lands at 0.6.31). The substrate''s halves: the COPY pin detects in-store drift; the STRUCTURAL pin survives reload. Equal structural digests are evidence, not proof; unequal ARE proof of difference.' END);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj,
    'modules', v_rows, 'drifted', v_drift,
    'completeness', jsonb_build_object(
      'verdict', CASE WHEN v_has_src THEN 'complete for recorded loads'
                      ELSE 'UNKNOWN — engine predates loader-side recording' END,
      'counters', ckp._engine_counters()),
    'note', 'drifted:true means an adopted module''s graph no longer matches its first-composition pin — the module was swapped or edited under an unsuperseded Adoption. A legitimate update arrives as a NEW Adoption + Supersession, which re-pins.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.wave_signals(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  W text := 'https://conceptkernel.org/ontology/v3.11/wave#';
  v_proj  text := ckp._project();
  v_pass  int  := (p_payload->>'pass')::int;
  -- component alias convention: c-<project, dashes stripped> (c-pgck, c-pgckmcp);
  -- override with {component} where the convention doesn't hold (ck-lib-js → c-cklib).
  v_comp  text := COALESCE(p_payload->>'component', W||'c-'||replace(v_proj,'-',''));
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
  v_this jsonb; v_next jsonb; v_sig jsonb;
BEGIN
  -- THIS PASS — everything stamped with the number, any of the six stamps.
  IF v_pass IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'type', regexp_replace(i.body->>'type','^.*[/#]',''),
        'by',   i.body->>(C||'producedBy'),
        'judged', (i.body ? (C||'conformsToShape'))) ORDER BY i.ts_created), '[]'::jsonb)
      INTO v_this
    FROM ckp.instances i
    WHERE COALESCE((i.body->>(W||'discoveredAtPass'))::numeric, -1) = v_pass
       OR COALESCE((i.body->>(W||'resolvedAtPass'))::numeric,  -1) = v_pass
       OR COALESCE((i.body->>(W||'ruledAtPass'))::numeric,     -1) = v_pass
       OR COALESCE((i.body->>(W||'opAtPass'))::numeric,        -1) = v_pass
       OR COALESCE((i.body->>(W||'rebasedAtPass'))::numeric,   -1) = v_pass
       OR i.body->>(W||'forPass') = W||'pass-'||v_pass;
  END IF;

  -- THE NEXT-PASS QUEUE — derived, so carry-over is never a memory exercise.
  v_next := jsonb_build_object(
    'openFindings', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'label', left(COALESCE(i.body->>'http://www.w3.org/2000/01/rdf-schema#label',
                               i.body->>(W||'label')), 140),
        'by', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Finding' AND i.body->>(W||'findingState') = 'open'),
    'pendingProposals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'about', i.body->>(C||'about'), 'op', i.body->>(C||'proposalOp'),
        'by', i.body->>(C||'createdBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = C||'Proposal'
        AND i.body->>(C||'proposalState') = 'pending'
        AND NOT i.body ? (C||'retiredAtEpoch')),
    'inbox', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'opKind', i.body->>(W||'opKind'),
        'from', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Operation'
        -- 0.4.62: opTarget has no canonical spelling — components address this
        -- kernel as its wave alias, its kernel URN, or its kernel/ck graph. Two
        -- escalations from ck-dev sat unseen for a day because this matched the
        -- alias alone. Same defect family as the intoProject spellings.
        AND i.body->>(W||'opTarget') IN (v_comp,
              'urn:ckp:'||v_proj||'/kernel', 'urn:ckp:'||v_proj||'/kernel/ck')));

  -- SIGNALS — health counts a third party can recompute. Never one boolean.
  v_sig := jsonb_build_object(
    'unjudged',       (SELECT count(*) FROM ckp.instances i
                       WHERE COALESCE((i.body->>(C||'sealedAtEpoch'))::numeric, -1) >= 1
                         AND NOT i.body ? (C||'conformsToShape')),
    'preEnforcement', (SELECT count(*) FROM ckp.instances i
                       WHERE NOT i.body ? (C||'sealedAtEpoch')),
    'anonymousSeals', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>(C||'createdBy') LIKE 'urn:ckp:participant:anon%'),
    'openFindings',   (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = W||'Finding'
                         AND i.body->>(W||'findingState') = 'open'),
    'pendingProposalsFleet', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = C||'Proposal'
                         AND i.body->>(C||'proposalState') = 'pending'
                         AND NOT i.body ? (C||'retiredAtEpoch')),
    -- 0.4.65 (§5b): the agreements guarding this kernel's seal-exit. A guard
    -- two parties agreed to must be READABLE by the third who meets it.
    'obligations',    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                         'obligation', o.obligation,
                         'targetType', regexp_replace(o.target_type,'^.*[/#]',''),
                         'check', o.check_name,
                         'sinceEpoch', o.added_epoch) ORDER BY o.obligation), '[]'::jsonb)
                       FROM ckp.proof_obligations o
                       WHERE o.active AND o.project = v_proj));

  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj, 'component', v_comp, 'epoch', v_epoch,
    'pass', v_pass, 'thisPass', COALESCE(v_this, '[]'::jsonb),
    'next', v_next, 'signals', v_sig,
    -- 0.4.71 — R-11 (pgRDF I9): every list-shaped reply states its
    -- completeness, and this census is INCOMPLETE BY CONSTRUCTION until its
    -- measured blind spots close. Three legitimate arrivals were missed in one
    -- day; a reader who treats this as the whole wire builds on absence.
    'completeness', jsonb_build_object(
      'verdict', 'INCOMPLETE — blind spots declared below',
      'blindSpots', jsonb_build_array(
        'thisPass matches only the six *AtPass stamps and forPass — an unstamped fact (e.g. a Confirmation) is invisible here',
        'inbox matches opTarget in three spellings of THIS component — an Operation addressed to another component, or a fourth spelling, is invisible',
        'openFindings/pendingProposals are fleet-wide, but Passes and Epochs of other projects are not surfaced',
        'no acknowledgement lifecycle: answered Operations remain in inbox forever'),
      'counters', ckp._engine_counters()),
    'boundary', 'THIS pass = facts stamped with its number + the epochs they advanced; closed at Index seal. NEXT pass = this `next` object AT close — derived, never remembered. NEXT wave = when bindsRoot moves. unjudged means sealedAtEpoch>=1 with conformsToShape ABSENT: admitted, ledgered, judged by nothing — the fence.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';            -- state names (no quote/space)
  v_op       text := p_prop->>(C||'proposalOp');
  v_detail   jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_class    text;
  v_path     text;
  v_min      int;
  v_dtype    text;
  v_dt_line  text := '';
  v_map      jsonb;
  v_fs       text;
  v_ts       text;
  v_ttl      text;
  -- 0.4.67 — NAMED SHAPES, NEVER BRACKETS. The `[ a sh:NodeShape … ]` form
  -- minted an anonymous NodeShape into the KERNEL graph — a blank node in the
  -- doctrine. That breaks two things at once: the doctrine stops being
  -- byte-pinnable (existential-free is the fleet rule, measured 22/22 ground
  -- on this kernel), and a shape nobody can name can never be superseded by
  -- name. Caught by the rule BEFORE any governed add_class ever fired on a
  -- live kernel — the first prevented defect of the alignment. The shape IRI
  -- is deterministic (project + local names + an 8-hex discriminator over the
  -- full IRIs), so re-applying the same op re-emits the same subject.
  -- Project segment from the SEALED producedBy — server-derived, never parsed
  -- from a caller field.
  v_seg      text := (regexp_match(COALESCE(p_prop->>(C||'producedBy'),''), '^urn:ckp:([^/]+)/kernel'))[1];
  v_shape    text;
BEGIN
  IF v_op = 'add_property' THEN
    v_class := v_detail->>'targetClass';
    v_path  := v_detail->>'path';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: targetClass must be an IRI, got %', v_class; END IF;
    IF v_path IS NULL OR v_path !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: path must be an IRI, got %', v_path; END IF;
    BEGIN
      v_min := COALESCE((v_detail->>'minCount')::int, 1);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'add_property: minCount must be an integer, got %', v_detail->>'minCount'; END;
    v_dtype := v_detail->>'datatype';
    IF v_dtype IS NOT NULL THEN
      IF v_dtype !~ v_iri_re THEN RAISE EXCEPTION 'add_property: datatype must be an IRI, got %', v_dtype; END IF;
      v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
    END IF;
    IF v_seg IS NULL THEN
      RAISE EXCEPTION 'add_property: cannot derive the project segment from the proposal''s producedBy — a shape must be NAMED into a kernel graph, never anonymous'; END IF;
    v_shape := format('urn:ckp:%s/shape/%s--%s--%s', v_seg,
                      ckp._slug(regexp_replace(v_class,'^.*[/#:]','')),
                      ckp._slug(regexp_replace(v_path,'^.*[/#:]','')),
                      left(md5(v_class||'|'||v_path),8));
    -- the PROPERTY shape is named too — `sh:property [ … ]` would put the
    -- blank node right back into the doctrine through the inner bracket.
    RETURN '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '<'||v_shape||'> a sh:NodeShape ; sh:targetClass <'||v_class||'> ; '||
           'sh:property <'||v_shape||'/p> .'||chr(10)||
           '<'||v_shape||'/p> sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' .';

  ELSIF v_op = 'add_class' THEN
    v_class := COALESCE(v_detail->>'class', v_detail->>'targetClass', p_prop->>(C||'about'));
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_class: class must be an IRI, got %', v_class; END IF;
    -- detail.properties[] WAS ACCEPTED AND SILENTLY DROPPED. The op emitted one
    -- quad (<class> a owl:Class) and reported graph_changed:true, so a caller
    -- who declared constraints got a class carrying none and no complaint --
    -- the same family as detail/proposalDetail and the inert epoch. Reported by
    -- pgCK.MCP against urn:ckp:pgck-mcp/type/ToolProjection: two property
    -- shapes sent, one quad applied, nothing validatable.
    --
    -- Emit the NodeShape too, with the same per-property gate add_property uses.
    -- A malformed property is REFUSED here, never dropped: silently narrowing a
    -- shape is un-enforcement nobody sees.
    IF v_seg IS NULL THEN
      RAISE EXCEPTION 'add_class: cannot derive the project segment from the proposal''s producedBy — a shape must be NAMED into a kernel graph, never anonymous'; END IF;
    v_shape := format('urn:ckp:%s/shape/%s--%s', v_seg,
                      ckp._slug(regexp_replace(v_class,'^.*[/#:]','')),
                      left(md5(v_class),8));
    v_ts := ''; v_ttl := '';
    IF jsonb_typeof(v_detail->'properties') = 'array' THEN
      FOR v_map IN SELECT jsonb_array_elements(v_detail->'properties') LOOP
        v_path := v_map->>'path';
        IF v_path IS NULL OR v_path !~ v_iri_re THEN
          RAISE EXCEPTION 'add_class: property path must be an IRI, got %', v_path; END IF;
        BEGIN
          v_min := COALESCE((v_map->>'minCount')::int, 1);
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'add_class: property minCount must be an integer, got %', v_map->>'minCount'; END;
        v_dtype := v_map->>'datatype';
        v_dt_line := '';
        IF v_dtype IS NOT NULL THEN
          IF v_dtype !~ v_iri_re THEN
            RAISE EXCEPTION 'add_class: property datatype must be an IRI, got %', v_dtype; END IF;
          v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
        END IF;
        -- named property shapes (…/p0, /p1, …): the inner bracket was the
        -- other half of the bnode emission — see the DECLARE note.
        v_fs := v_shape||'/p'||left(md5(v_path),8);
        v_ts := v_ts||' ; sh:property <'||v_fs||'>';
        v_ttl := v_ttl||'<'||v_fs||'> sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' .'||chr(10);
      END LOOP;
    END IF;
    IF v_ts = '' THEN
      -- bare declaration: a building block for a following add_property. NOTE it
      -- is admitted the moment it lands (_type_admitted accepts `a owl:Class`),
      -- so until a shape targets it an instance of this type validates
      -- VACUOUSLY. That window is a doctrine question, not a projector bug.
      RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
             '<'||v_class||'> a owl:Class .';
    END IF;
    -- 0.4.71 — A SHAPE CAN BE LOCKED AND ENFORCED: detail.closed = true emits
    -- sh:closed with sh:ignoredProperties, so an undeclared key REFUSES at the
    -- gate instead of minting into the type namespace. The default ignore list
    -- is the substrate envelope — rdf:type, the four server stamps,
    -- participant, and the board timestamps — because those are derived onto
    -- every candidate and a closed shape that forgets them refuses EVERYTHING
    -- (the total-write-outage-presenting-as-bad-data class). Callers extend it
    -- via detail.ignoredProperties (IRIs, gated). Closing a FLEET type demands
    -- the same care through governance: enumerate its client-stamped envelope
    -- first, or the close is a denial of service dressed as rigor.
    IF COALESCE(v_detail->>'closed','false') = 'true' THEN
      v_fs := ' <http://www.w3.org/1999/02/22-rdf-syntax-ns#type>'
            ||' <'||C||'createdBy> <'||C||'producedBy> <'||C||'sealedAtEpoch>'
            ||' <'||C||'conformsToShape> <'||C||'participant>'
            ||' <urn:ckp:board/created_at> <urn:ckp:board/created_by>';
      IF jsonb_typeof(v_detail->'ignoredProperties') = 'array' THEN
        FOR v_path IN SELECT jsonb_array_elements_text(v_detail->'ignoredProperties') LOOP
          IF v_path !~ v_iri_re THEN
            RAISE EXCEPTION 'add_class: ignoredProperties entry must be an IRI, got %', v_path; END IF;
          v_fs := v_fs||' <'||v_path||'>';
        END LOOP;
      END IF;
      v_ts := v_ts||' ; sh:closed true ; sh:ignoredProperties ('||v_fs||' )';
    END IF;
    RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
           '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '<'||v_class||'> a owl:Class .'||chr(10)||
           '<'||v_shape||'> a sh:NodeShape ; sh:targetClass <'||v_class||'>'||v_ts||' .'||chr(10)||
           v_ttl;

  ELSIF v_op = 'set_transition_map' THEN
    v_class := v_detail->>'targetClass';
    v_map   := v_detail->'map';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'set_transition_map: targetClass must be an IRI, got %', v_class; END IF;
    IF v_map IS NULL OR jsonb_typeof(v_map) <> 'object' THEN
      RAISE EXCEPTION 'set_transition_map: map must be an object {from:[to,…]}'; END IF;
    v_ttl := '@prefix ckp: <'||C||'> .'||chr(10);
    FOR v_fs IN SELECT jsonb_object_keys(v_map) LOOP
      IF v_fs !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad from-state %', v_fs; END IF;
      IF jsonb_typeof(v_map->v_fs) <> 'array' THEN
        RAISE EXCEPTION 'set_transition_map: map[%] must be an array of to-states', v_fs; END IF;
      FOR v_ts IN SELECT jsonb_array_elements_text(v_map->v_fs) LOOP
        IF v_ts !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad to-state %', v_ts; END IF;
        v_ttl := v_ttl || '<'||v_class||'> ckp:allowsTransition '||
                 '[ ckp:fromState "'||v_fs||'" ; ckp:toState "'||v_ts||'" ] .'||chr(10);
      END LOOP;
    END LOOP;
    RETURN v_ttl;

  END IF;
  -- Ops without a shape projection yet (modify_shape_constraint, set_quorum,
  -- set_materialize_policy) leave the graph unchanged here; add_affordance with a query
  -- is handled by ckp.apply's register step. Translators land as each is built.
  RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._dispatch_safe(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  v_out := ckp.dispatch(p_verb, p_payload);
  RETURN v_out;
EXCEPTION
  WHEN OTHERS THEN
    -- The refusal is the RESULT. Carry the clause the gate named, plus SQLSTATE
    -- so a caller can tell a shape refusal from a transport fault, and keep the
    -- verb so a Trace-Id correlation still resolves. Never re-raise: re-raising
    -- is what killed the worker.
    --
    -- 0.4.71 — RESET THE ENGINE'S TERM CACHE after the aborted subtransaction.
    -- Any term FIRST-interned inside the abort is poisoned: it stores but SHACL
    -- cannot see it, so a caller's RETRY reusing the same fresh IRIs refuses
    -- with "MinCount not satisfied" on a field its body demonstrably carries.
    -- Measured three times on this wave (s56's flake class, s64's build, and
    -- pgck's own reconciliation seal taking three attempts); the suites carry
    -- per-file resets, but door callers had no protection until here — the
    -- catch block is the one place that KNOWS an abort just happened. Guarded:
    -- engines without the remedy skip silently, and a reset failure must never
    -- eat the refusal we owe the caller.
    BEGIN
      IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN
        PERFORM pgrdf.shmem_reset();
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN jsonb_build_object(
      'ok',      false,
      'refused', true,
      'verb',    p_verb,
      'sqlstate', SQLSTATE,
      'error',   SQLERRM
    );
END;
$function$;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
