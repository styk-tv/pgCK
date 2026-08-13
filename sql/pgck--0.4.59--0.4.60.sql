-- pgck 0.4.60 — the declared map agrees with the gate, and the fourth spelling.
--
-- (1) ckp._propmap now includes shapes targeting the type's ANCESTORS. The gate
-- always applied them (the parent-closure stamp is what makes ParticipantShape
-- reach a wave#Component), but surface.declared and the create-path key
-- resolution read only the type's own shapes — so core#participantKind was
-- required by the gate and absent from the declared contract. Measured
-- independently by pgrdf-mcp (three refusals to learn it) and pgRDF.
-- (2) ckp._adopted_graphs matches the FOURTH intoProject spelling,
-- urn:ckp:project/<p> — found by pgRDF in their own sealed doctrine, where
-- copying it into an Adoption produced a valid record that composed nothing.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

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
  -- 0.4.60 — ANCESTORS INCLUDED. The gate validates the candidate against
  -- shapes targeting the type AND its ancestors (the parent-closure stamp is
  -- exactly what makes ParticipantShape reach a wave#Component), but this map
  -- read only shapes targeting the type itself. So core#participantKind was
  -- REQUIRED by the gate and ABSENT from surface.declared — measured
  -- independently by pgrdf-mcp ("the declared map and the gate disagree about
  -- the contract", three refusals to learn it) and by pgRDF. The composed
  -- graph is materialized, so subClassOf closure is present as direct triples;
  -- both branches are self-contained (branch-local — the #114-safe form).
  v_q   text := $q$
    PREFIX sh:   <http://www.w3.org/ns/shacl#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?path WHERE { GRAPH <%1$s> {
      { ?s sh:targetClass <%2$s> ; sh:property ?p . ?p sh:path ?path }
      UNION
      { <%2$s> rdfs:subClassOf ?anc . ?s sh:targetClass ?anc ; sh:property ?p . ?p sh:path ?path }
    } }
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
  -- (ancestors included since 0.4.60 — see v_q above)
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._adopted_graphs(p_project text)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
BEGIN
  -- Sealed, unsuperseded Adoptions of THIS project, in seal order.
  --
  -- 0.4.57 — THE THIRD SPELLING, found by pgck-mcp the hard way. This accepted
  -- 'urn:ckp:<p>' and 'urn:ckp:<p>/kernel/ck' and MISSED 'urn:ckp:project:<p>' —
  -- which is the MOST principled form, because germinate_kernel seals exactly
  -- that IRI as the ckp:Project @id and the kernel's inProject points at it. So
  -- a caller who read the graph and used the Project's real IRI sealed an
  -- Adoption that was judged by AdoptionShape, ledgered, proof-digested — and
  -- silently composed NOTHING. Measured by pgck-mcp (adoption at their seq 159,
  -- intoEpoch 4, then a full materialization at epoch 5: modules [], digest
  -- unchanged) and filed as the surface.modules ask on this kernel. pgCK's own
  -- adoptions worked only because they copied A3's bare spelling — the composer
  -- rewarded the accident and ignored the principle. A sealed record whose
  -- declared value has no effect is R2's defect shape, inside the composer.
  RETURN COALESCE((
    SELECT array_agg(a.body->>(N||'adopts') ORDER BY a.ts_created)
    FROM ckp.instances a
    WHERE a.body->>'type' = N||'Adoption'
      AND a.body->>(N||'adopts') IS NOT NULL
      -- 0.4.60: pgRDF found the FOURTH spelling in their own sealed doctrine —
      -- urn:ckp:project/<p>, slash not colon (their kernel graph's inProject
      -- carries it). Anyone copying their sealed doctrine into an Adoption got
      -- a valid, load-bearing-for-nothing record. All four forms match now;
      -- the real cure (one canonical spelling at seal) is a shape question.
      AND a.body->>(N||'intoProject') IN ('urn:ckp:'||p_project,
                                          'urn:ckp:'||p_project||'/kernel/ck',
                                          'urn:ckp:project:'||p_project,
                                          'urn:ckp:project/'||p_project)
      AND NOT EXISTS (
        SELECT 1 FROM ckp.instances s
        WHERE s.body->>'type' = N||'Supersession'
          AND s.body->>(N||'supersedes') = a.body->>'@id')
  ), ARRAY[]::text[]);
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
