-- pgck 0.4.54 — the case-resolution rule only worked for kernels shaped like mine.
--
-- 0.4.51 resolved one kernel to one spelling by asking which SEALED ckp:Kernel a
-- transport segment means. That closed the split for pgck, which has one, and did
-- NOTHING for a kernel that exists only as a GRAPH. pgRDF's own report exposed it;
-- pgCK's project.resolve verb then measured it:
--     pgrdf -> clause 4 -> pgrdf   (urn:ckp:pgrdf/kernel/ck EMPTY)
--     pgRDF -> clause 5 -> pgRDF   (urn:ckp:pgRDF/kernel/ck, 25 triples, their doctrine)
--     sealedKernelsMatching [] for both
-- Two spellings, two surfaces — the exact defect 0.4.51 shipped to end, still open
-- one kernel over, because the fix could only see kernels built the way mine was.
--
-- The ordering principle is corrected, not extended: PREFER THE SPELLING WITH
-- SUBSTANCE (sealed beats non-empty graph), never "prefer the canonical spelling".
-- Pointing pgrdf at its empty canonical graph would be tidy and would lose their
-- doctrine. The substrate derives from a fact; it does not have opinions about
-- names.
--
-- Self-retiring: the day a kernel seals a ckp:Kernel under its canonical name,
-- clauses 1-2 take over and both spellings resolve there.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

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
    RETURN regexp_replace(v_hits[1], '^urn:ckp:(.*)/kernel/ck$', '\1');
  ELSIF v_hits IS NOT NULL AND array_length(v_hits, 1) > 1 THEN
    RAISE EXCEPTION '%', format(
      'ckp._project: kernel id %L is ambiguous — %s non-empty kernel graphs answer to it case-insensitively (%s), and none carries a sealed ckp:Kernel to break the tie. Seal a ckp:Kernel under the canonical spelling; that resolves it permanently.',
      v_raw, array_length(v_hits, 1), array_to_string(v_hits, ', '));
  END IF;
  -- 5. nothing behind any spelling. A canonical name is the germination path and
  --    MUST stay open, or kernel.germinate is unreachable for every project that
  --    does not exist yet.
  IF v_raw ~ CANON THEN
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

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
