-- pgck 0.4.51 — the type gate was never scoped, and one kernel had two names.
--
-- Rulings on pgCK.MCP PASS-v0.2.45, plus two defects neither party had.
-- Full record, with the re-runnable gate for each: CKP.v3.11.pgCK.PASS-30.md.
--
--  1. ckp._type_admitted   THE GATE WAS SUBSTRATE-WIDE. It scoped itself with
--                          ASK { GRAPH ?g { …UNION… } FILTER(?g IN (<comp>,<board>)) }
--                          and pgrdf DOES NOT APPLY THAT FILTER under the UNION.
--                          Measured live: the same ASK restricted to a graph that
--                          does not exist returns true, and <http://ex/T> — declared
--                          only in urn:sh:probe, a five-triple SHACL scratch graph —
--                          is an admitted type for every kernel on the bench. A TEST
--                          FIXTURE WIDENED THE PRODUCTION TYPE GATE. Now: one
--                          constant-graph ASK per surface, combined in PL/pgSQL,
--                          where the combination cannot be optimised away.
--
--  2. ckp._project         THE NAME WAS VALIDATED WHERE KERNELS ARE BORN AND
--                          UNVALIDATED WHERE FACTS ARE SEALED. germinate_kernel
--                          refuses a non-canonical segment; _project applied no rule
--                          and the relay sets the GUC verbatim from the NATS subject.
--                          One kernel came to exist twice — urn:ckp:pgck/instances
--                          holds sealed projections of BOTH urn:ckp:project:pgck and
--                          urn:ckp:project:pgCK. Now resolved against a SEALED
--                          ckp:Kernel: exact wins, one case-insensitive match resolves
--                          to the sealed spelling, two REFUSE naming both, and a name
--                          with no kernel must be one germination would accept.
--
--  3. ckp._propmap         NEW, and it replaces FOUR inline copies that DID NOT
--                          AGREE: create_typed/query/update_typed read the kernel
--                          graph while validate_instance read the composed surface,
--                          so validate and create could map one JSON key to two IRIs
--                          — validate ⟺ seal broken one layer below the gate. Also
--                          the trap that springs on adoption: wave:FindingShape
--                          requires rdfs:label and ckp:reason, neither in the kernel
--                          graph, so a Finding's two required properties were minted
--                          into the wave namespace and the two the shape demands were
--                          absent. Harmless only while nothing gates the type.
--
--  4. ckp.affordances_of   THE ADVERTISED SURFACE WAS NOT THE ROUTABLE ONE. Its
--                          `unsealed` set filtered r.kernel = p_project while
--                          registry_lookup resolves (p_kernel OR the 'pgck' substrate
--                          floor), so a kernel read "I may lawfully call nothing" and
--                          then sealed successfully. Now derived THROUGH
--                          registry_lookup, so enumerable ⟺ dispatchable by
--                          construction rather than by two queries agreeing.
--
--  5. ckp.dispatch         edge.create sealed urn:ckp:board/Edge and notify sealed
--                          urn:ckp:board/Message — classes declared in ONE file,
--                          examples/example.kernel.ttl, which no module can load. Zero
--                          rows fleet-wide mention either. The paths COULD NOT SEAL
--                          FOR ANY PARTICIPANT ON ANY SURFACE, regardless of grants.
--                          The class is now the caller's to name; property IRIs follow
--                          its namespace; a caller naming none is refused with the
--                          reason. 0.4.42's comment asserting these classes "now carry
--                          shapes in the project kernel graph" is withdrawn in
--                          _type_admitted: an unverified claim in a comment is the same
--                          defect class as an unenforced constraint in a shape.
--
--  6. the type envelope    ABSENT and PRESENT-BUT-NOT-READABLE-HERE now differ, and
--                          create reads the SAME two payload shapes validate reads.
--                          {"@type": …} used to fall through to the task.create
--                          concretion and be told "kernel and title required" — an
--                          error about a verb the caller did not call. A nested
--                          {"body": {"type": …}} used to VALIDATE and then fail to
--                          CREATE, which is validate ⟺ seal broken at the envelope.
--
-- GENERATED from sql/pgck-baseline.sql. The upgrade path and the fresh-install
-- path are therefore the same bytes rather than two hand-written copies that
-- agree today — which is the drift class PASS-12 recorded and PASS-13 measured.

CREATE OR REPLACE FUNCTION ckp._type_admitted(p_type text, p_project text, p_comp integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_comp_iri text; v_board_iri text; v_ask text; v_q text;
BEGIN
  IF p_type IS NULL OR position(':' in p_type) = 0 THEN
    RETURN false;   -- no resolvable type is not an admitted type
  END IF;
  -- 0.4.42: the #46 TRANSITIONAL ALLOWANCE IS DELETED. It read "tolerate it until
  -- #46 re-points the body construction, at which point the board path becomes
  -- non-vacuously validated". While it stood, R2 was open on the write path — seal
  -- consults this function, so a v3.7 type reached the SHACL gate, was targeted by
  -- no shape, took a VACUOUS conforms:true and sealed. An undeclared type is now
  -- refused whatever namespace it carries.
  --
  -- 0.4.51 — CORRECTION, and it is this file's own claim being withdrawn. 0.4.42
  -- also asserted here that "urn:ckp:board/{Task,Goal,Edge,Message} now carry
  -- shapes in the project kernel graph", i.e. that its exit condition was met.
  -- THEY DO NOT. Those four are declared in exactly one place,
  -- examples/example.kernel.ttl, which no module can load — import_module knows
  -- {task, goal} and both are retired. Measured fleet-wide, twice, by two
  -- parties: zero rows mention urn:ckp:board/Edge in any graph. The board
  -- defaults are removed from edge.create and notify in this same version, so
  -- the claim is not merely corrected, its subject is gone.
  --
  -- The lesson is R1 turned on our own comments: a sentence asserting a gate is
  -- a claim, and an unverified claim in a comment is the same defect class as an
  -- unenforced constraint in a shape. It survived because nobody re-ran it.
  -- Admitted = the type is DECLARED (a shape targets it, or it is a declared
  -- class) anywhere the kernel loaded: the composed core+ck surface OR the
  -- project board. Reads the same surfaces the gate/self-test consult — never
  -- a second authority. An invented URN in none of them is refused.
  --
  -- 0.4.51 — THE SCOPE WAS NEVER ENFORCED, AND THAT IS THE WHOLE GATE.
  -- This asked ONE query shaped
  --     ASK { GRAPH ?g { …UNION…UNION… } FILTER(?g IN (<comp>, <board>)) }
  -- and pgrdf DOES NOT APPLY THAT FILTER under the UNION. Measured live
  -- (PASS-30 §1): the identical ASK restricted to a graph that does not exist
  -- returns TRUE for a module-declared class, and returns TRUE for <http://ex/T>,
  -- a type declared only in urn:sh:probe — a five-triple SHACL scratch graph.
  -- So a TEST FIXTURE WIDENED THE PRODUCTION TYPE GATE, and every type declared
  -- anywhere on the substrate was admitted for every kernel.
  --
  -- The consequence is the state pgCK.MCP filed as F10. The type gate read the
  -- whole store while the shape gate read the composed surface, so a class the
  -- store declares and the surface does not shape was ADMITTED and then judged
  -- by nothing — SHACL is target-driven, so validation never ran, and the seal
  -- omitted conformsToShape honestly. Three correct components, two of them
  -- reading different stores.
  --
  -- The same FILTER on a plain BGP is REJECTED as untranslatable; only the UNION
  -- form drops it silently. So the one shape pgCK shipped is the one shape that
  -- fails open, with no log line. The fix does not argue with the engine: it
  -- issues ONE CONSTANT-GRAPH ASK PER SURFACE and combines them HERE, where the
  -- combination is plpgsql and cannot be optimised away. A graph that does not
  -- exist answers false rather than raising (measured), so the board arm is safe
  -- for every project that never imported one.
  v_comp_iri  := pgrdf.graph_iri(p_comp);
  v_board_iri := format('urn:ckp:%s/kernel/board', p_project);
  v_q := $q$
    PREFIX sh:   <http://www.w3.org/ns/shacl#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX owl:  <http://www.w3.org/2002/07/owl#>
    ASK WHERE { GRAPH <%1$s> {
      { ?s sh:targetClass <%2$s> } UNION { <%2$s> a rdfs:Class } UNION { <%2$s> a owl:Class }
    } }
  $q$;
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask
  FROM pgrdf.sparql(format(v_q, v_comp_iri, p_type)) j LIMIT 1;
  IF COALESCE(v_ask, 'false') = 'true' THEN
    RETURN true;
  END IF;
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask
  FROM pgrdf.sparql(format(v_q, v_board_iri, p_type)) j LIMIT 1;
  RETURN COALESCE(v_ask, 'false') = 'true';
END;
$function$
;

-- 0.4.51 — WHICH KERNEL DID THE CALLER MEAN? Resolved from a SEALED FACT, not
-- from the transport string.
--
-- ckp.germinate_kernel refuses any project failing ^[a-z0-9]+(-[a-z0-9]+)*$ --
-- one lowercase transport segment. ckp._project() applied NO rule at all, and
-- the inbound relay sets ckp.project VERBATIM from the NATS subject segment
-- (inbound_dispatch.rs). So THE NAME WAS VALIDATED WHERE KERNELS ARE BORN AND
-- UNVALIDATED WHERE FACTS ARE SEALED, and one kernel came to exist twice.
--
-- Measured on the bench (PASS-30): urn:ckp:pgck/instances holds sealed
-- projections of BOTH urn:ckp:project:pgck AND urn:ckp:project:pgCK, and of
-- BOTH urn:ckp:pgck/kernel AND urn:ckp:pgCK/kernel, all four labelled "pgCK";
-- urn:ckp:pgCK/instances holds 14 triples from the A3 adoption act; and
-- neither urn:ckp:pgCK/kernel/ck nor urn:ckp:pgCK/shapes/composed exists. The
-- split never surfaced as an error because registry_lookup resolves the
-- substrate floor row under the literal 'pgck', so ROUTING SURVIVED IT while
-- composition, adoption and the epoch did not.
--
-- Slugging the segment would have been the silent fix, and silent is the
-- disease: it would have re-pointed three kernels that were germinated before
-- the canonical rule existed (urn:ckp:pgRDF/kernel/ck and
-- urn:ckp:SuperAiHarness3000/kernel/ck are LOCKED graphs with 25 triples each)
-- onto empty surfaces, with no error anywhere. So the resolution asks a fact
-- instead of transforming a string:
--
--   1. the segment is canonical AND a sealed ckp:Kernel carries it exactly -> it
--   2. exactly one CANONICAL sealed kernel matches case-insensitively      -> that one
--   3. more than one canonical match                                       -> REFUSE, naming them
--   4. no sealed kernel, and the segment is canonical                      -> pass (germination)
--   5. no sealed kernel, non-canonical, but urn:ckp:<seg>/kernel/ck EXISTS -> grandfathered
--   6. otherwise                                                           -> REFUSE with the slug
--
-- THE ORDER WAS DESIGNED AGAINST THE LIVE INVENTORY, NOT AGAINST A PREFERENCE,
-- and the first draft of it was wrong in both directions — measured before it
-- shipped, which is the only reason it is not in the release:
--
--   * "exact match always wins" preserved the split it exists to close. BOTH
--     urn:ckp:pgCK/kernel and urn:ckp:pgck/kernel are sealed, so `pgCK` matched
--     exactly and resolved to itself forever. Hence clause 1's canonical guard:
--     a non-canonical spelling can never win by exactness alone, so `pgCK` falls
--     to clause 2 and lands on the sealed kernel that a germination would have
--     produced.
--   * "refuse anything non-canonical without a sealed kernel" stranded two live
--     components. urn:ckp:pgRDF/kernel/ck and urn:ckp:SuperAiHarness3000/kernel/ck
--     are LOCKED graphs with 25 triples each and NO sealed ckp:Kernel — they were
--     germinated before the canonical rule existed. Clause 5 grandfathers exactly
--     those: the substrate still derives from a fact (their kernel graph), just a
--     weaker one than a seal. It admits no NEW non-canonical name, because a name
--     with neither a seal nor a graph has nothing behind it.
--
-- Clause 3 is not a policy choice either. Two CANONICAL sealed kernels answering
-- to one name is a genuine conflict, and guessing which one a caller meant is
-- how the phantom project was written in the first place.
--
-- Clause 5's exit condition, stated so it cannot be forgotten: it disappears the
-- day those two kernels are re-germinated under canonical names, or seal a
-- ckp:Kernel of their own. It is a legacy allowance with a named end, not a knob.
--
-- It RAISEs rather than returning a sentinel because ckp._dispatch_safe already
-- turns a RAISE into {ok:false, refused:true, sqlstate, error} data (0.4.41),
-- so the door answers with the clause and the worker lives. Read paths fail
-- closed for the same reason writes do.
CREATE OR REPLACE FUNCTION ckp._project()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N       text := 'https://conceptkernel.org/ontology/v3.11/core#';
  -- ONE definition of "which project is this". Twelve call sites resolved it
  -- inline in two spellings that DISAGREED on the empty string: ckp.dispatch
  -- mapped '' to '', everything else mapped '' to 'demo' -- so an empty GUC
  -- sent the affordance lookup and the write to different kernels.
  --
  -- The 'demo' fallback is itself a real kernel name, which makes it a landing
  -- site for writes that belong to nobody. It lives HERE now, in one place, so
  -- it can be made fail-closed in a single edit instead of twelve.
  CANON   text := '^[a-z0-9]+(-[a-z0-9]+)*$';
  v_raw   text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_kid   text;
  v_hits  text[];
  v_ask   text;
BEGIN
  v_kid := 'urn:ckp:'||v_raw||'/kernel';
  -- 1. a CANONICAL spelling with its own sealed kernel wins outright. This is the
  --    common path and costs one indexless scan of a small table. The canonical
  --    guard is load-bearing: without it a non-canonical twin resolves to itself
  --    and the split it exists to close survives (measured — see above).
  IF v_raw ~ CANON AND EXISTS (SELECT 1 FROM ckp.instances i
              WHERE i.body->>'type' = N||'Kernel' AND i.body->>'@id' = v_kid) THEN
    RETURN v_raw;
  END IF;
  -- 2/3. resolve case-insensitively against the CANONICAL sealed kernels — the
  --      ones a germination today would have produced.
  SELECT array_agg(DISTINCT i.body->>'@id') INTO v_hits
    FROM ckp.instances i
   WHERE i.body->>'type' = N||'Kernel'
     AND lower(i.body->>'@id') = lower(v_kid)
     AND regexp_replace(i.body->>'@id', '^urn:ckp:(.*)/kernel$', '\1') ~ CANON;
  IF v_hits IS NOT NULL AND array_length(v_hits, 1) = 1 THEN
    RETURN regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel$', '\1');
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    -- RAISE takes only `%`; a `%L` here would print the value followed by a
    -- literal L. Format first, raise the formatted string. (Caught by the
    -- negative control, which is the argument for having written one.)
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s sealed kernels answer to it case-insensitively (%s). One kernel must have one spelling; resolve it by governance (seal a ckp:Supersession for the one that is not authoritative) rather than by guessing here.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 4. no sealed kernel, canonical name: the germination path. Must stay open or
  --    kernel.germinate is unreachable for every project that does not yet exist.
  IF v_raw ~ CANON THEN
    RETURN v_raw;
  END IF;
  -- 5. GRANDFATHER, with a named exit. A kernel germinated before the canonical
  --    rule has a kernel/ck graph and no sealed ckp:Kernel. Still a fact, just a
  --    weaker one. Asked over the sanctioned surface rather than pgrdf's catalog,
  --    and a graph that does not exist answers false rather than raising.
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask
  FROM pgrdf.sparql(format('ASK WHERE { GRAPH <urn:ckp:%s/kernel/ck> { ?s ?p ?o } }', v_raw)) j
  LIMIT 1;
  IF COALESCE(v_ask, 'false') = 'true' THEN
    RETURN v_raw;
  END IF;
  -- 6. neither a seal nor a graph stands behind this name. Refuse with the slug,
  --    the same message germination gives, so the two doors teach one rule.
  RAISE EXCEPTION '%', format(
    'ckp._project: kernel id %L is not canonical, no sealed kernel carries it and no kernel graph stands behind it. A project name is lowercase, dashes optional, one transport segment — use %L. (ckp.germinate_kernel refuses the same name; this door now applies the same rule, so a fact can never be sealed into a project that could not be germinated.)',
    v_raw, ckp._slug(regexp_replace(v_raw, '^.*[:/]', '')));
END;
$function$
;

-- 0.4.51 — ONE definition of "which properties does this type declare".
--
-- Four call sites resolved this inline and THEY DID NOT AGREE. create_typed,
-- ckp.query and update_typed read urn:ckp:<proj>/kernel/ck; validate_instance
-- read urn:ckp:<proj>/shapes/composed. So `instance.validate` and
-- `instance.create` mapped the SAME JSON to DIFFERENT property IRIs, which is
-- validate ⟺ seal (R3/G3) broken one layer beneath the gate everyone was
-- watching: validate could resolve `reason` to ckp:reason while create minted
-- <type-namespace>reason, and the caller is told its body conformed.
--
-- The kernel-graph-only read is also the trap that springs on adoption. A
-- module type's shape may require a FOREIGN property — wave:FindingShape
-- requires rdfs:label and ckp:reason — and neither is in the kernel graph, so
-- the map came back empty and both keys fell through to the type's own
-- namespace. Harmless only for as long as nothing gates the type. See PASS-30
-- §4: emission and shape move in one act.
--
-- Composed FIRST, kernel LAST, so a kernel's own declaration wins over a stale
-- composed copy of it and the module/core paths are still resolvable. Never
-- fewer entries than the old read; the caller's fallback is unchanged for what
-- neither graph declares.
--
-- p_composed exists for ONE declared exception: ckp.query uses this map to
-- REFUSE undeclared filter keys, so widening it there would newly refuse reads
-- that resolve today (e.g. filtering on a substrate-stamped key no shape
-- declares). That is a tightening other components have not asked for, so it is
-- held here as a named argument with a reason rather than taken silently. Flip
-- it when the read surface is ready, in its own act.
CREATE OR REPLACE FUNCTION ckp._propmap(p_type text, p_project text, p_composed boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_map jsonb := '{}'::jsonb;
  v_g   text;
  v_gs  text[];
  v_q   text := $q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?path WHERE { GRAPH <%1$s> {
      ?s sh:targetClass <%2$s> ; sh:property ?p . ?p sh:path ?path } }
  $q$;
BEGIN
  IF p_type IS NULL OR btrim(p_type) = '' THEN
    RETURN v_map;
  END IF;
  v_gs := CASE WHEN p_composed
               THEN ARRAY[format('urn:ckp:%s/shapes/composed', p_project),
                          format('urn:ckp:%s/kernel/ck', p_project)]
               ELSE ARRAY[format('urn:ckp:%s/kernel/ck', p_project)] END;
  FOREACH v_g IN ARRAY v_gs LOOP
    SELECT v_map || COALESCE(jsonb_object_agg(regexp_replace(path, '^.*[/#]', ''), path), '{}'::jsonb)
      INTO v_map
    FROM (
      SELECT DISTINCT j->>'path' AS path
        FROM pgrdf.sparql(format(v_q, v_g, p_type)) AS j
       WHERE j->>'path' IS NOT NULL
    ) p;
  END LOOP;
  RETURN v_map;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.affordances_of(p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N       text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_kern  text := 'urn:ckp:'||p_project||'/kernel/ck';
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = p_project), 0);
  v_comp  int;
  v_list  jsonb;
  v_unsealed jsonb;
BEGIN
  v_comp := ckp._composed_shapes(p_project);

  SELECT jsonb_agg(a ORDER BY a->>'name') INTO v_list FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'name',    regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', ''),
      'iri',     i.body->>'@id',
      'in',      i.body->>(N||'inTopic'),
      'out',     i.body->>(N||'outTopic'),
      'plane',   i.body->>(N||'plane'),
      'delegate', (i.body->>(N||'delegate'))::boolean,
      'inShape', i.body->>(N||'inShape'),
      -- inShape resolved into a real input contract, or null + a marker. §4.5:
      -- report what was found; never invent a contract for a dangling IRI.
      'schema',  ckp._affordance_schema(i.body->>(N||'inShape'), v_comp),
      'schema_resolved',
                 CASE WHEN i.body ? (N||'inShape')
                      THEN ckp._affordance_schema(i.body->>(N||'inShape'), v_comp) IS NOT NULL
                      ELSE NULL END,
      -- provenance for the affordance ITSELF (root: derivedBy minCount 1)
      'derivedBy', i.body->>(N||'derivedBy'),
      'sealedAtEpoch', (i.body->>(N||'sealedAtEpoch'))::int
    )) AS a
    FROM ckp.instances i
    WHERE i.body->>'type' = N||'Affordance'
      -- kernel filter: producedBy is the substrate-stamped kernel, unforgeable
      AND i.body->>(N||'producedBy') = v_kern
      -- retirement honoured: retired AT or BEFORE the current epoch is gone
      AND (NOT (i.body ? (N||'retiredAtEpoch'))
           OR (i.body->>(N||'retiredAtEpoch'))::int > v_epoch)
  ) s;

  -- The #56 split, made VISIBLE: verbs dispatch resolves that no sealed
  -- Affordance declares. Reported, never merged — a union would hide exactly
  -- the hand-registered action the root says cannot hide.
  --
  -- 0.4.51 — THE ADVERTISED SURFACE WAS NOT THE ROUTABLE ONE. This filtered
  -- `r.kernel = p_project`, while ckp.registry_lookup resolves
  -- `r.kernel = p_kernel OR r.kernel = 'pgck'` — the substrate floor seeded at
  -- install, which belongs to no kernel because install runs before any kernel
  -- exists. So a kernel that had registered two verbs of its own read
  -- {derived: [], unsealed: [its two]} and then SEALED SUCCESSFULLY through
  -- instance.create, a verb neither list named. pgCK.MCP filed that as F11 and
  -- inferred `derived` counts materialized affordances while instance-plane
  -- verbs are granted by role; the inference is refuted — both lists answer the
  -- same question, and they answered it against different predicates.
  --
  -- The fix is not a matching WHERE clause, which would drift again the next
  -- time the router changes. The candidate set is now filtered THROUGH
  -- registry_lookup itself, so "what this kernel may lawfully call" has exactly
  -- one definition and enumerable ⟺ dispatchable holds by construction. That is
  -- R7 / G7 closed by single-sourcing rather than by syncing two stores.
  SELECT jsonb_agg(q.verb ORDER BY q.verb) INTO v_unsealed
  FROM (
    SELECT DISTINCT r.verb
      FROM ckp.affordance_registry r
     WHERE ckp.registry_lookup(p_project, r.verb) IS NOT NULL
  ) q
  WHERE NOT EXISTS (
      SELECT 1 FROM ckp.instances i
      WHERE i.body->>'type' = N||'Affordance'
        AND i.body->>(N||'producedBy') = v_kern
        AND regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', '') = q.verb);

  RETURN jsonb_build_object(
    'ok', true,
    'kernel', p_project,
    'epoch', v_epoch,
    'affordances', COALESCE(v_list, '[]'::jsonb),
    'unsealed', COALESCE(v_unsealed, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- 0.4.51: read the SAME payload shapes ckp.validate_instance reads. It did
  -- COALESCE(p_payload->'body', p_payload) and this did not, so a nested
  -- {body:{type,…}} VALIDATED and then failed to CREATE — validate ⟺ seal
  -- broken at the envelope, one level above where it was broken at the
  -- property map. Both are closed in this version, in the same act, because
  -- fixing one and not the other just moves the disagreement.
  v_in      jsonb := CASE WHEN jsonb_typeof(p_payload->'body') = 'object'
                            AND ((p_payload->'body') ? 'type')
                          THEN p_payload->'body' ELSE p_payload END;
  v_type    text := v_in->>'type';
  v_proj    text := ckp._project();
  -- F-A / P0-C (pgCK#26): identity is SERVER-DERIVED from the verified
  -- connection (the ckp.requester GUC the trusted ingress sets from the
  -- NATS-verified bearer), NEVER the client payload. A payload {sub} is
  -- ignored — it cannot forge created_by or the participant claim. This is
  -- the same rule task.create and notify already carry; the generic path
  -- was the last reader of payload sub (measured: s58's instance.create
  -- case sealed participant:attacker before this fix).
  v_sub     text := current_setting('ckp.requester', true);
  N         text := 'urn:ckp:board/';       -- v3.7 core NS (gate + task.create)
  v_core    text[] := ARRAY['lifecycle_state'];                       -- recognized core keys → core NS
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    -- 0.4.51 — ABSENT is not the same as PRESENT-BUT-NOT-READABLE-HERE, and the
    -- old error said the first when the second was true. A caller following
    -- JSON-LD habit sends {"@type": …} and is told it gave no type; a caller
    -- nesting {"type": …, "body": {…}} is told the same. Both then re-send the
    -- one field they already sent. pgCK.MCP lost two calls to exactly this
    -- (F9) before reading the spec. Name the shape instead of the field.
    IF p_payload ? '@type' OR (jsonb_typeof(p_payload->'body') = 'object'
                               AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}} — the same two shapes instance.validate reads. NOT accepted: @type, which is never read.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 0.4.51: the SAME map validate_instance uses. It read the kernel graph while
  -- validate read composed, so validate and create could resolve one JSON key to
  -- two different IRIs. See ckp._propmap.
  v_propmap := ckp._propmap(v_type, v_proj);

  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_in)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id', 'participant');     -- control keys, not data (sub/participant: identity is never payload)
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                             -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                                 -- declared localname -> its path IRI
    ELSIF v_key = ANY(v_core) THEN
      v_keyiri := N || v_key;                                        -- v3.7 core key -> core NS (gate + task.create)
    ELSE
      v_keyiri := v_ns || v_key;                                     -- other undeclared -> under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);         -- `->` value: preserves number/bool/object types
  END LOOP;

  v_body := v_body || jsonb_build_object(
    'urn:ckp:board/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    -- created_by from the VERIFIED requester (same shape as task.create), and
    -- the participant claim seal maps to core#participant — also verified.
    v_body := v_body || jsonb_build_object(
      N||'created_by', 'urn:ckp:participant:'||ckp._slug(v_sub),
      'participant', jsonb_build_object('sub', v_sub));
  END IF;

  PERFORM ckp.seal(v_iid, v_body);

  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.query(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := ckp._project();
  v_ops     jsonb := '{"eq":"=","neq":"<>","lt":"<","lte":"<=","gt":">","gte":">=","contains":"LIKE"}'::jsonb;
  v_key_re  text := '^[A-Za-z][A-Za-z0-9:#/._-]*$';   -- the unshaped-fallback key gate
  v_propmap jsonb;          -- declared localname -> full path IRI ({} when the type is unshaped)
  v_shaped  boolean;
  v_where   text;
  v_limit   int := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 100), 1), 1000);
  v_offset  int := GREATEST(COALESCE((p_payload->>'offset')::int, 0), 0);
  f         jsonb;
  v_op text; v_key_in text; v_key text; v_val text;
  v_sql text; v_result jsonb;
BEGIN
  IF v_type IS NULL OR v_type !~ '^[A-Za-z]' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type', 'type', v_type);
  END IF;

  -- Derive the type's declared property map. 0.4.51: one definition
  -- (ckp._propmap), and this is the ONE declared exception to it — p_composed
  -- false keeps the kernel-graph read, because v_shaped below turns the map
  -- into a REFUSAL set for filter keys. Widening it here would newly refuse
  -- reads that resolve today against substrate-stamped keys no shape declares.
  -- Held as a named argument with a reason rather than tightened silently.
  v_propmap := ckp._propmap(v_type, v_proj, false);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_where := format('(body->>%L) = %L', 'type', v_type);   -- base: this instance type only

  FOR f IN SELECT jsonb_array_elements(COALESCE(p_payload->'filter', '[]'::jsonb)) LOOP
    v_op := f->>'op'; v_key_in := f->>'key'; v_val := f->>'value';
    IF NOT (v_ops ? v_op) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_operator', 'op', v_op,
                                'allowed', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_ops) k));
    END IF;

    -- KEY RESOLUTION.
    IF v_shaped THEN
      -- shaped type: the key MUST be a declared property (by localname or full IRI).
      IF v_propmap ? v_key_in THEN
        v_key := v_propmap->>v_key_in;                                   -- declared localname -> IRI
      ELSIF v_key_in IS NOT NULL
            AND EXISTS (SELECT 1 FROM jsonb_each_text(v_propmap) e WHERE e.value = v_key_in) THEN
        v_key := v_key_in;                                              -- already a declared full IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_filter_key',
                                  'key', v_key_in, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      -- unshaped for THIS session's project (the shape isn't in urn:ckp:<project>/kernel/ck, or
      -- the type is genuinely unshaped). Resolve the key against the ACTUAL instance-body keys —
      -- exact full-IRI OR by localname suffix — so the filter runs against the key the bodies use,
      -- independent of the shape/project read (pgCK#6). Bare-key bodies (localname == key) resolve
      -- to themselves, so s29 back-compat holds.
      IF v_key_in IS NULL OR v_key_in !~ v_key_re THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_filter_key', 'key', v_key_in);
      END IF;
      SELECT bk INTO v_key
      FROM ckp.instances i
      CROSS JOIN LATERAL jsonb_object_keys(i.body) AS bk
      WHERE i.body->>'type' = v_type
        AND (bk = v_key_in OR regexp_replace(bk, '^.*[/#]', '') = v_key_in)
      LIMIT 1;
      IF v_key IS NULL THEN
        -- NEVER a silent [] (pgCK#6): the key maps to no stored property on this type.
        IF EXISTS (SELECT 1 FROM ckp.instances WHERE body->>'type' = v_type) THEN
          RETURN jsonb_build_object('ok', false, 'error', 'unresolved_shape',
                                    'key', v_key_in, 'type', v_type,
                                    'hint', 'no shape for this type in the session project and no instance carries this property key');
        END IF;
        v_key := v_key_in;   -- no instances of this type: the filtered read is legitimately empty
      END IF;
    END IF;

    -- WHERE construction (unchanged operator logic; quote_literal values + enum operators).
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
  RETURN jsonb_build_object('ok', true, 'type', v_type, 'shaped', v_shaped,
                            'count', COALESCE(jsonb_array_length(v_result), 0),
                            'rows', COALESCE(v_result, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.update_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id      text := p_payload->>'id';
  v_patch   jsonb := p_payload->'patch';
  v_proj    text := ckp._project();
  v_cur     jsonb;
  v_type    text;
  v_ns      text;
  v_propmap jsonb;
  v_shaped  boolean;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_id IS NULL OR btrim(v_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_required'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id); END IF;

  v_type := v_cur->>'type';
  v_ns   := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;

  -- declared property map for the instance's type (same read as create_typed).
  -- 0.4.51: composed-aware, because a patch is a WRITE and must resolve keys the
  -- same way the gate will judge them. Refusing an undeclared patch key earlier,
  -- with the declared set named, is strictly better than sealing it under the
  -- type's namespace and letting the gate refuse the whole body.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_cur := v_cur - 'participant';   -- re-resolved by ckp.seal from any supplied claims

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    CONTINUE WHEN v_key IN ('id', 'type', '@id');   -- not patchable via this path
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                    -- already a full IRI
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
    END IF;
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);
  v_type    text := v_body->>'type';
  v_proj    text := ckp._project();
  v_subj    text := 'urn:ckp:validate:'||pg_backend_pid();
  v_ns      text;
  v_propmap jsonb;
  v_resolved jsonb;
  v_key text; v_val jsonb; v_kiri text;
  v_scratch bigint;
  v_comp    int;
  v_ttl     text;
  v_report  jsonb;
BEGIN
  IF v_type IS NULL THEN
    -- 0.4.51 — the payload IS read as COALESCE(p_payload->'body', p_payload), so
    -- flat {type, …} and nested {body:{type, …}} both work and
    -- {type, body:{…}} is the ONE shape that cannot: the type sits outside the
    -- body this descends into. Saying "type_required" there names the single
    -- field the caller DID supply, and the caller re-sends it. Distinguish.
    IF p_payload ? '@type' OR p_payload ? 'type'
       OR (jsonb_typeof(p_payload->'body') = 'object' AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}}. NOT accepted: @type (never read), or {"type": …, "body": {…}} — that puts the type outside the body this verb descends into.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;

  -- P0-D mechanism 2 parity (pgCK#27): validate PREDICTS seal. seal refuses an
  -- undeclared type before the SHACL gate; validate must report the same, or
  -- validate <=> seal is a slogan. An undeclared type reports conforms=false
  -- with a violation naming it — never the vacuous conforms=true that let
  -- invented types look valid.
  v_comp := ckp._composed_shapes(v_proj);
  BEGIN
    IF NOT ckp._type_admitted(v_type, v_proj, v_comp) THEN
      RETURN jsonb_build_object('ok', true, 'type', v_type, 'conforms', false,
        'violations', jsonb_build_array(jsonb_build_object(
          'focusNode', v_type, 'resultMessage', 'type is not admitted — no shape targets it and it is declared by no class',
          'sourceConstraintComponent', 'ckp:AdmittedTypeConstraint')),
        'report', jsonb_build_object('conforms', false));
    END IF;
  END;

  -- Resolve the body's short keys to declared property IRIs (mirror ckp.create_typed) so validate
  -- accepts the same {type, …fields} shape as instance.create. Already-IRI keys pass through.
  v_ns := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;
  -- 0.4.51: the SAME map create_typed uses. This read composed while create read
  -- the kernel graph — validate ⟺ seal broken one layer below the gate.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_resolved := jsonb_build_object('type', v_type);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_body) LOOP
    CONTINUE WHEN v_key IN ('type', '@id', 'sub');
    IF position(':' in v_key) > 0 THEN v_kiri := v_key;
    ELSIF v_propmap ? v_key THEN v_kiri := v_propmap->>v_key;
    ELSE v_kiri := v_ns || v_key; END IF;
    v_resolved := v_resolved || jsonb_build_object(v_kiri, v_val);
  END LOOP;

  -- project the resolved candidate body to RDF in a scratch graph.
  v_ttl := ckp._body_to_ttl(v_resolved, v_subj, v_comp);
  v_scratch := pgrdf.add_graph('urn:ckp:validate:'||pg_backend_pid());
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    PERFORM pgrdf.parse_turtle(v_ttl, v_scratch, 'urn:ckp:validate#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'detail', SQLERRM);
  END;

  -- Full native W3C SHACL Core report against the COMPOSED SURFACE -- the graph
  -- ckp.seal actually gates on. This validated against <urn:ckp:%s/kernel/ck>,
  -- which holds a Kernel and three organs and NO shapes: measured on the bench,
  -- 30 triples and 0 sh:targetClass, versus a composed surface of 1258 triples
  -- and 27 targets. Nothing could ever be selected, and the only thing standing
  -- between that and a vacuous conforms:true is the no-target guard.
  -- "validate PREDICTS seal" (pgCK#27) was a slogan on all three axes -- shapes
  -- graph, property map, serializer overload. All three now match seal.
  v_report := pgrdf.validate(v_scratch, v_comp, 'native');
  PERFORM pgrdf.clear_graph(v_scratch);

  RETURN jsonb_build_object('ok', true, 'type', v_type,
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb),
    'report',     v_report);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  req    jsonb := p_payload->'req';
  res    jsonb;
  v_proj text := ckp._project();
  v_idk  text := COALESCE(current_setting('ckp.identity_key', true), 'pgck-localhost');
  v_canon  text;   -- CI-B-2: canonical instance.* name (registry lookup key)
  v_aff    jsonb;  -- CI-B-1: the sealed affordance row (the registry IS the routing authority)
  v_legacy text;   -- CI-B-2: the legacy handler name (alias window)
BEGIN
  PERFORM set_config('ckp.project', v_proj, false);
  PERFORM set_config('ckp.identity_key', v_idk, false);

  -- CI-B-1/B-2 — the sealed registry is the SOLE routing authority. Resolve the canonical
  -- name + its sealed affordance row; an unregistered verb fails typed (unknown_affordance)
  -- with zero payload evaluation (no fallthrough); a delegate=true row is the Tier-2 tool
  -- seam; governance-plane verbs never execute here (proposal/vote/apply — CI-D). Otherwise
  -- resolve the legacy handler name (alias window) so the CASE below is unchanged and v0.3.0
  -- web2 keeps working.
  v_canon := ckp.verb_canon(p_verb);
  -- Resolve against the CALLING project, not a fixed kernel. This asked
  -- registry_lookup('pgck', ...) for every caller, so a verb registered by any
  -- other kernel was invisible and every non-pgck workspace got
  -- unknown_affordance. It looked correct only because the seed and the
  -- registrars were hard-coded to the same literal -- writer and reader wrong
  -- in the same direction. (smoke-s4 s41: registered under 's41-test',
  -- resolved under 'pgck'.)
  v_aff   := ckp.registry_lookup(v_proj, v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable',
      'plane', 'governance', 'verb', p_verb, 'canonical', v_canon)
      || jsonb_build_object('req', req);
  -- Tier 2 (3/3b): a governed query affordance (SPARQL text sealed via the governance plane,
  -- compiled into ckp.plans at apply) routes here. The caller binds typed params only; the query
  -- text is the kernel's OWN sealed fact, never caller input.
  ELSIF v_aff->>'plane' = 'query' THEN
    RETURN ckp.run_query_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  -- Scoring-loop layer 3: a governed DERIVED-read affordance ({formula, scope} sealed via the
  -- governance plane, compiled into ckp.plans at apply) routes here. The caller binds only the
  -- concept; the formula is the kernel's OWN sealed fact. Returns the band-less {ok, value,
  -- scored, freshness} envelope — the role-floor-reachable read surface the scoring client calls.
  ELSIF v_aff->>'plane' = 'derived' THEN
    RETURN ckp.run_derived_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  END IF;
  -- CI-E-5: instance.query is the typed derived-QueryShape read (the legacy instances.list alias
  -- keeps its list behavior below — routed by the ORIGINAL verb, not the shared canonical).
  IF p_verb = 'instance.query' THEN
    RETURN ckp.query(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.reach' THEN
    RETURN ckp.reach(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.transition' THEN
    RETURN ckp.transition(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.snapshot' THEN
    RETURN ckp.snapshot(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'concept.match' THEN
    RETURN ckp.concept_match(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.explain' THEN
    RETURN ckp.explain(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.retire' THEN
    RETURN ckp.retire(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.validate' THEN
    RETURN ckp.validate_instance(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 (v0.4.4): generic typed create. A uniform {type:<class IRI>, …fields} body
  -- routes to the §4 generic path, which seals it against the kernel's OWN declared shape.
  -- The discriminator is a TOP-LEVEL `type`: the legacy concretion forms carry no top-level
  -- `type` (task.create -> {task:{…}}, kernel.create -> {name:…}). `name` is NOT a usable
  -- discriminator here — it is a perfectly ordinary property on a generic type — so a `{task}`
  -- body still wins (the established concretion path) but everything else with a `type` is generic.
  -- 0.4.51: `@type` and a nested `{body:{type}}` route here TOO, so the teaching
  -- refusal is reachable. Without this a caller following JSON-LD habit fell
  -- through to the task.create concretion and was told "kernel and title
  -- required" — an error about a verb it did not call, naming fields it never
  -- heard of. create_typed answers `type_not_readable_here` and names the two
  -- shapes that ARE read. Routing on a key it will then refuse is deliberate:
  -- the alternative is a correct-looking error from the wrong handler, which is
  -- the class of misdirection F9 filed.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type' OR p_payload ? '@type'
             OR (p_payload ? 'body' AND ((p_payload->'body') ? 'type' OR (p_payload->'body') ? '@type')))
        AND NOT (p_payload ? 'task') THEN
    RETURN ckp.create_typed(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 / v0.5 T4: generic typed update. instance.update with a `patch` sub-object patches
  -- by the type's declared properties (re-sealed); the legacy flat {id,…fields} form falls
  -- through to verb_to_legacy -> task.update.
  ELSIF p_verb = 'instance.update' AND (p_payload ? 'patch') THEN
    RETURN ckp.update_typed(p_payload) || jsonb_build_object('req', req);
  END IF;
  v_legacy := ckp.verb_to_legacy(p_verb, p_payload);

  CASE v_legacy

  -- ---- generic URN-addressed instance ops (the main goal) --------------
  WHEN 'instances.list', 'instances.last', 'instances.count', 'instance.get' THEN
    res := ckp._query(v_legacy, p_payload);

  -- ---- discovery -------------------------------------------------------
  -- B4: the surface in force, checked against the digests its epoch sealed.
  -- A READ, never a gate — a false positive here would take the substrate down,
  -- and legitimate drift exists. Findings name what was measured; empty = pass.
  WHEN 'surface.check' THEN
    res := ckp.surface_check(v_proj);

  -- B3: the store-level G-1 audit — the cross-node integrity body locality puts
  -- beyond the instance gate (§4.5). B1a: authority resolved by traversal, with
  -- an empty chain reported AS empty (persona spec §3).
  WHEN 'integrity.check' THEN
    res := ckp.integrity_check(v_proj);

  WHEN 'authority.mine' THEN
    res := ckp.authority_of(NULL);

  WHEN 'affordances' THEN
    -- B1 (pgCK#56): derived from SEALED ckp:Affordance instances of THIS kernel,
    -- carrying inShape resolved into a real input contract, retirement honoured,
    -- and the registry/sealed drift reported under `unsealed` rather than merged.
    -- Was: an unfiltered SPARQL scan of a graph nobody writes, which returned []
    -- for a substrate holding sealed affordances — reads as "no grants", means
    -- "nothing declared".
    res := ckp.affordances_of(v_proj);

  WHEN 'kernels.list' THEN
    res := jsonb_build_object('ok', true, 'kernels', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', COALESCE(body->>RL, regexp_replace(id,'^backlog:','')),
        'id', id, 'urn', 'ckp://Kernel#'||ckp._slug(COALESCE(body->>RL, regexp_replace(id,'^backlog:','')))) ORDER BY id)
      FROM ckp.instances WHERE body->>'type' = N||'Goal' AND id LIKE 'backlog:%'), '[]'::jsonb));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1),
        'ledger', COALESCE((SELECT jsonb_agg(jsonb_build_object('seq',seq,'prev_seq',prev_seq,'body_sha256',body_sha256,'ts',ts) ORDER BY seq) FROM ckp.ledger WHERE instance_id=tid),'[]'::jsonb));
    END;

  WHEN 'instance.verify' THEN
    res := jsonb_build_object('ok', true, 'id', p_payload->>'id', 'verified', ckp.verify(p_payload->>'id'));

  -- ---- participant input (kernel governs by sealing) -------------------
  WHEN 'participant.join' THEN
    res := jsonb_build_object('ok', true, 'sub', p_payload->>'name',
      'urn', 'urn:ckp:participant:'||ckp._slug(p_payload->>'name'));

  -- 0.4.43: germination as a GOVERNED act. kernel.create seals a board Goal and
  -- creates no kernel; the pgRDF route creates a correct kernel that belongs to
  -- nobody. This is the one that does both: client declares structure, substrate
  -- stamps ckp:ownedBy from the verified connection.
  WHEN 'kernel.germinate' THEN
    res := ckp.germinate_kernel(
             COALESCE(p_payload->>'project', p_payload->>'name'),
             p_payload->>'label',
             COALESCE(p_payload->>'projectKind', 'personal'));

  WHEN 'kernel.create' THEN
    DECLARE nm text := p_payload->>'name'; gid text;
    BEGIN
      IF nm IS NULL OR btrim(nm)='' THEN res := jsonb_build_object('ok',false,'error','kernel name required');
      ELSE
        gid := 'backlog:'||nm;
        PERFORM ckp.seal(gid, jsonb_build_object('type', N||'Goal', '@id', 'ckp://Goal#'||gid, N||'goal_id', gid,
          RL, nm, N||'title', nm, N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        res := jsonb_build_object('ok',true,'kernel',nm,'id',gid);
      END IF;
    END;

  WHEN 'task.create' THEN
    DECLARE t jsonb := p_payload->'task'; k text := p_payload->'task'->>'target_kernel';
            -- F-A (pgCK#9/#10): identity is SERVER-DERIVED from the verified connection
            -- (the ckp.requester GUC the trusted ingress sets from the NATS-verified bearer),
            -- NEVER the client payload. A payload {sub} is ignored — it cannot forge created_by.
            sub text := current_setting('ckp.requester', true); tid text; qseq int; v_body jsonb;
    BEGIN
      IF k IS NULL OR (p_payload->'task'->>'title') IS NULL THEN
        res := jsonb_build_object('ok',false,'error','kernel and title required');
      ELSE
        SELECT COALESCE(MAX((i.body->>(N||'queue_seq'))::int),0)+1 INTO qseq
          FROM ckp.instances i WHERE i.body->>(N||'target_kernel')=k AND i.body->>'type'=N||'Task';
        tid := 'task-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        v_body := jsonb_build_object('type', N||'Task', '@id', 'ckp://Task#'||tid, N||'task_id', tid,
          N||'title', t->>'title', N||'part_of_goal', 'backlog:'||k, N||'target_kernel', k,
          N||'lifecycle_state', COALESCE(t->>'lifecycle_state','planned'),
          N||'priority', COALESCE(t->'priority','5'::jsonb), N||'queue_seq', to_jsonb(qseq),
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN
          v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub),
                                             'participant', jsonb_build_object('sub', sub));
        END IF;
        PERFORM ckp.seal(tid, v_body);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  WHEN 'task.update' THEN
    DECLARE tid text := p_payload->>'id'; cur jsonb; v_fld text;
    BEGIN
      SELECT body INTO cur FROM ckp.instances WHERE id=tid;
      IF cur IS NULL THEN res := jsonb_build_object('ok',false,'error','instance not found');
      ELSE
        cur := cur - 'participant';
        -- Apply EVERY patchable task field the caller sent (closed allow-list = the task
        -- model's mutable properties; never arbitrary keys), preserving JSON type with ->
        -- not ->> so a number stays a number end-to-end. Pre-0.4.3 this hardcoded only
        -- lifecycle_state + priority — it silently dropped title (CK.Lib.Js report 2.1) and
        -- ->> coerced priority 1 → "1" (report 2.2).
        FOREACH v_fld IN ARRAY ARRAY['title','priority','lifecycle_state','part_of_goal','target_kernel'] LOOP
          IF p_payload ? v_fld THEN
            cur := cur || jsonb_build_object(N||v_fld, p_payload->v_fld);
          END IF;
        END LOOP;
        PERFORM ckp.seal(tid, cur);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- board snapshot (web protocol verb the browser surfaces use) -------
  WHEN 'snapshot.board' THEN
    res := jsonb_build_object('ok', true,
      'kernels', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', i.body->>(N||'title'), 'id', i.id)
                    ORDER BY i.body->>(N||'title')), '[]'::jsonb)
                  FROM ckp.instances i WHERE i.body->>'type' = N||'Goal'),
      'tasks', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', i.id,
                  'title', i.body->>(N||'title'),
                  'target_kernel', i.body->>(N||'target_kernel'),
                  'part_of_goal', i.body->>(N||'part_of_goal'),
                  'lifecycle_state', i.body->>(N||'lifecycle_state'),
                  'priority', i.body->(N||'priority'),
                  'queue_seq', i.body->(N||'queue_seq'),
                  'created_by', i.body->>(N||'created_by'),
                  'proof_digest', (SELECT p.digest FROM ckp.proof p WHERE p.about = i.id ORDER BY p.id DESC LIMIT 1),
                  'verified', ckp.verify(i.id))
                  ORDER BY i.body->>(N||'target_kernel'), NULLIF(i.body->>(N||'queue_seq'),'')::int), '[]'::jsonb)
                FROM ckp.instances i WHERE i.body->>'type' = N||'Task'));

  -- ---- raw instance bodies — bulk replay for CKHexStore + corpus capture ---
  -- returns the literal IRI-keyed JSON-LD bodies (with @id + type), the shape a
  -- browser quad store ingests and a fixture corpus records (SPEC.CK.HEXSTORE Q4).
  WHEN 'snapshot.bodies' THEN
    DECLARE k text := p_payload->>'kernel';
    BEGIN
      res := jsonb_build_object('ok', true,
        'bodies', (SELECT coalesce(jsonb_agg(i.body ORDER BY i.id), '[]'::jsonb)
                   FROM ckp.instances i
                   WHERE k IS NULL OR i.body->>(N||'target_kernel') = k));
    END;

  -- ---- concept link (Edge) — captured so the structure is recoverable ---
  -- 0.4.51 — THE EDGE CLASS IS THE CALLER'S TO NAME, AND WAS A DEFAULT NOTHING
  -- DECLARED. This sealed N||'Edge' = urn:ckp:board/Edge unconditionally. That
  -- class is declared in ONE file, examples/example.kernel.ttl, which no module
  -- can load (import_module knows {task, goal}), so the path COULD NOT SEAL FOR
  -- ANY PARTICIPANT ON ANY KERNEL SURFACE, regardless of grants — measured by
  -- pgCK.MCP as F6 and re-measured here: SELECT ?g ?p WHERE { GRAPH ?g { ?s ?p
  -- <urn:ckp:board/Edge> } } returns ZERO ROWS fleet-wide.
  --
  -- Worse, 0.4.42's own comment in ckp._type_admitted asserted the exit
  -- condition was met — "urn:ckp:board/{Task,Goal,Edge,Message} now carry shapes
  -- in the project kernel graph". They do not. That sentence is deleted with
  -- this default; a comment claiming a gate is a claim, and R1 applies to
  -- claims about our own code exactly as it applies to shapes.
  --
  -- The kernel declares what an edge IS; the substrate refuses what violates
  -- that. So the class comes from the caller and the property IRIs follow ITS
  -- namespace — the same rule create_typed's fallback already uses. A caller
  -- that names no class is REFUSED with the reason, never sealed under a class
  -- nobody declared.
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_etype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_ens   text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF v_etype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','edge_type_required',
          'hint','instance.link requires {type}: the edge class THIS kernel declares (sh:targetClass or a declared rdfs:Class/owl:Class in its composed surface). There is no substrate default — the former one, urn:ckp:board/Edge, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_etype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','instance.link {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Edge');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        v_ens := regexp_replace(v_etype, '[^/#]*$', '');    -- the declared class's namespace
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', v_etype, '@id', 'ckp://Edge#'||eid,
          v_ens||'source', src, v_ens||'predicate', pred, v_ens||'target', tgt, v_ens||'topic', topic,
          v_ens||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'type',v_etype,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  -- 0.4.51 — the SAME defect as edge.create, one class along, and untested by
  -- the party who found the first: this sealed N||'Message' = urn:ckp:board/
  -- Message, declared by no loadable module, so notify could not seal either.
  -- The class is the caller's to name; the property IRIs follow its namespace.
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := COALESCE(p_payload->>'predicate','notifies');
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
            v_mtype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_mns   text;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSIF v_mtype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','message_type_required',
          'hint','notify requires {type}: the message class THIS kernel declares. There is no substrate default — the former one, urn:ckp:board/Message, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_mtype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','notify {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Message');
      ELSE
        v_mns := regexp_replace(v_mtype, '[^/#]*$', '');
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', v_mtype, '@id', 'ckp://Message#'||mid,
          v_mns||'from', frm, v_mns||'to', tgt, v_mns||'predicate', pred, v_mns||'body', bdy, v_mns||'topic', topic,
          v_mns||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(v_mns||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'type',v_mtype,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
