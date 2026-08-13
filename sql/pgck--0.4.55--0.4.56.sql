-- pgck 0.4.56 — the resolver now says WHY, and there is only one of it.
--
-- ckp.project_resolve reported which clause fired by INFERRING it from the
-- outcome. The moment 0.4.54 added the graph-substance clause that inference went
-- wrong: `pgrdf -> pgRDF` resolved on a kernel GRAPH and was labelled
-- "clause 2 — the one CANONICAL sealed kernel", with sealedKernelsMatching []
-- printed directly beneath it, contradicting the label inside the same object.
--
-- A CHECKER THAT MISREPORTS ITS OWN REASON is the defect class this whole pass
-- exists to end, so the fix is not a better inference — it is to stop inferring.
-- ckp._project_explain holds the logic once and returns {project, clause, hits};
-- ckp._project is a thin reader of it. The hot path is unchanged and the
-- explanation cannot drift from the decision, because they are one execution.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

-- 0.4.56 — THE RESOLVER NOW SAYS WHY, AND THERE IS ONLY ONE OF IT.
--
-- ckp.project_resolve reported which clause fired by INFERRING it from the
-- outcome (`v_out <> v_seg` therefore clause 2). The moment 0.4.54 added the
-- graph-substance clause that inference was wrong: `pgrdf -> pgRDF` resolved on
-- a kernel GRAPH and was reported as "clause 2 — the one CANONICAL sealed
-- kernel", with `sealedKernelsMatching: []` printed directly beneath it,
-- contradicting the label in the same object.
--
-- A CHECKER THAT MISREPORTS ITS OWN REASON is the defect class this pass exists
-- to end, so the fix is not a better inference — it is to stop inferring. The
-- resolution logic lives HERE, once, and returns {project, clause, hits}.
-- ckp._project() is a thin reader of it, so the hot path is unchanged and the
-- explanation cannot drift from the decision: they are the same execution.
CREATE OR REPLACE FUNCTION ckp._project_explain()
 RETURNS jsonb
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
    RETURN jsonb_build_object('project', v_raw, 'clause',
      'clause 1 — canonical, and it carries its own sealed ckp:Kernel', 'hits', to_jsonb(v_hits));
  END IF;
  -- 2/3. resolve case-insensitively against the CANONICAL sealed kernels — the
  --      ones a germination today would have produced.
  SELECT array_agg(DISTINCT i.body->>'@id') INTO v_hits
    FROM ckp.instances i
   WHERE i.body->>'type' = N||'Kernel'
     AND lower(i.body->>'@id') = lower(v_kid)
     AND regexp_replace(i.body->>'@id', '^urn:ckp:(.*)/kernel$', '\1') ~ CANON;
  IF v_hits IS NOT NULL AND array_length(v_hits, 1) = 1 THEN
    RETURN jsonb_build_object('project', regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel$', '\1'),
      'clause', 'clause 2 — resolved onto the one CANONICAL SEALED kernel that answers to this name',
      'hits', to_jsonb(v_hits));
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    -- RAISE takes only `%`; a `%L` here would print the value followed by a
    -- literal L. Format first, raise the formatted string. (Caught by the
    -- negative control, which is the argument for having written one.)
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s sealed kernels answer to it case-insensitively (%s). One kernel must have one spelling; resolve it by governance (seal a ckp:Supersession for the one that is not authoritative) rather than by guessing here.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 4. NO SEALED KERNEL — RESOLVE ONTO THE SPELLING THAT HAS SUBSTANCE.
  --
  -- 0.4.54, and this gap was exposed by pgRDF's own report, not by pgCK. The
  -- 0.4.51 rule resolved case only against SEALED kernels, so it closed the split
  -- for pgck — which happens to have one — and did NOTHING for a kernel that
  -- exists only as a GRAPH. Measured with pgCK's own project.resolve verb:
  --     pgrdf -> clause 4 -> pgrdf   (urn:ckp:pgrdf/kernel/ck EMPTY)
  --     pgRDF -> clause 5 -> pgRDF   (urn:ckp:pgRDF/kernel/ck, 25 triples, their doctrine)
  -- sealedKernelsMatching [] for both. Two spellings, two surfaces, and the fix
  -- shipped to end exactly that could not see it. A rule that only works for
  -- kernels shaped like mine is not a rule.
  --
  -- The ordering principle is NOT "prefer the canonical spelling" — it is PREFER
  -- THE SPELLING WITH SUBSTANCE, sealed beating graph, because the substrate must
  -- derive from a fact rather than from a preference about names. Pointing pgrdf
  -- at its empty canonical graph would be canonically tidy and would lose their
  -- doctrine, which is the wrong trade every time.
  --
  -- Migration path, deliberately: the day a kernel seals a ckp:Kernel under its
  -- canonical name, clauses 1-2 take over and BOTH spellings resolve there. This
  -- clause retires itself; it is not a permanent tolerance.
  SELECT array_agg(DISTINCT g) INTO v_hits FROM (
    SELECT j->>'g' AS g FROM pgrdf.sparql(format($q$
      SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }
    $q$)) j
    WHERE lower(j->>'g') = lower(format('urn:ckp:%s/kernel/ck', v_raw))
  ) d;
  IF v_hits IS NOT NULL AND array_length(v_hits, 1) = 1 THEN
    RETURN jsonb_build_object('project', regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel/ck$', '\1'),
      'clause', 'clause 4 — no sealed kernel anywhere; resolved onto the one spelling whose kernel GRAPH has substance',
      'hits', to_jsonb(v_hits));
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s non-empty kernel graphs answer to it case-insensitively (%s), and none carries a sealed ckp:Kernel to break the tie. Seal a ckp:Kernel under the canonical spelling; that resolves it permanently.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 5. nothing behind any spelling. A canonical name is the germination path and
  --    MUST stay open, or kernel.germinate is unreachable for every project that
  --    does not exist yet.
  IF v_raw ~ CANON THEN
    RETURN jsonb_build_object('project', v_raw, 'clause',
      'clause 5 — canonical, nothing sealed or graphed behind it yet; the germination path stays open',
      'hits', '[]'::jsonb);
  END IF;
  -- 6. neither a seal nor a graph stands behind this name. Refuse with the slug,
  --    the same message germination gives, so the two doors teach one rule.
  RAISE EXCEPTION '%', format(
    'ckp._project: kernel id %L is not canonical, no sealed kernel carries it and no kernel graph stands behind it. A project name is lowercase, dashes optional, one transport segment — use %L. (ckp.germinate_kernel refuses the same name; this door now applies the same rule, so a fact can never be sealed into a project that could not be germinated.)',
    v_raw, ckp._slug(regexp_replace(v_raw, '^.*[:/]', '')));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._project()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  SELECT ckp._project_explain()->>'project';
$function$
;

CREATE OR REPLACE FUNCTION ckp.project_resolve(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  CANON text := '^[a-z0-9]+(-[a-z0-9]+)*$';
  v_seg text := COALESCE(p_payload->>'segment', ckp._project());
  v_ex  jsonb;
BEGIN
  -- 0.4.56: ASK THE RESOLVER, DO NOT RE-DERIVE IT. This used to infer the clause
  -- from the outcome and got it wrong the moment a clause was added — reporting
  -- "the one CANONICAL sealed kernel" for a resolution that came off a kernel
  -- GRAPH, with sealedKernelsMatching [] printed beneath it. The explanation is
  -- now a field of the decision, so the two cannot drift.
  PERFORM set_config('ckp.project', v_seg, true);
  BEGIN
    v_ex := ckp._project_explain();
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', true, 'segment', v_seg, 'resolves', null,
      'refused', true, 'canonical', (v_seg ~ CANON), 'reason', SQLERRM,
      'note', 'a refusal IS the result. One kernel has one spelling; this name resolves to none or to more than one.');
  END;
  RETURN jsonb_build_object('ok', true, 'segment', v_seg,
    'resolves', v_ex->>'project', 'clause', v_ex->>'clause',
    'canonical', (v_seg ~ CANON), 'matched', COALESCE(v_ex->'hits', '[]'::jsonb),
    'note', 'the answer AND the reason come from ckp._project_explain itself, never a copy of its rules.');
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
