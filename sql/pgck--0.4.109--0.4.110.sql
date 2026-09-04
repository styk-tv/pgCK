-- pgck 0.4.109 -> 0.4.110
--
-- THE CENSUS HAD A FLAG FOR A DANGLING MODULE AND NONE FOR A DANGLING PROJECT.
--
-- `fleet.adoptions` has carried `malformed` since 0.4.68: true when the ADOPTS
-- IRI names no non-empty graph — a judged Adoption composing nothing. That is
-- one half of the symmetry. The other half went unreported: an Adoption whose
-- `intoProject` names a project that HAS NO GRAPHS AT ALL. The module is fine,
-- the seal is fine, all four stamps are present, `malformed` reads false — and
-- the adoption is reachable by nobody, because `ckp._adopted_graphs(<p>)` is
-- only ever consulted for a project that has a surface to compose into.
--
-- MEASURED 2026-09-04, three benches, from a virgin floor on ck-allinone
-- v0.7.44. The bundle's init.sql hardcodes `urn:ckp:project:demo` in both
-- Adoption dispatches while `bootstrap_kernel` correctly follows the
-- configured `ckp.project`. So a deployment that names its kernel gets:
--
--     ckp.project              = ckone          (compose honoured)
--     pgck.kernels             = ckone,…        (compose honoured)
--     Adoption intoProject     = …:project:demo (hardcoded, NOT templated)
--     graphs urn:ckp:demo/*    = 0              ← the target does not exist
--     graphs urn:ckp:ckone/*   = 3
--     _adopted_graphs('ckone') = (empty)        ← the composer's own answer
--     module wave 495 quads · lexicon 357 quads ← loaded, paid for, unreachable
--
-- 852 quads of law are loaded and the kernel the artifact was configured to
-- serve can reach neither. `wave:Finding` — the type the fleet's whole filing
-- discipline runs on — refuses as not-admitted on a correctly-configured bench.
-- The substrate refuses HONESTLY there (undeclared types cannot seal; SHACL
-- would validate them vacuously), so nothing is judged by nothing. The damage
-- is confined to "you cannot use the modules you shipped" — but the CENSUS
-- called it healthy, and a census that reports a broken install as healthy is
-- the defect this migration closes.
--
-- Fixing init.sql is oci-germination's act (og#16). Making the substrate stop
-- calling it healthy is ours, and it does not wait on them. REPORTS, never
-- gates (B4): a seal-time refusal here would break every deployment that names
-- a project until the bundle ships, and a census is exactly the instrument that
-- may be wrong cheaply.
--
-- Predicate: strip the four `intoProject` spellings to a bare segment and ask
-- whether ANY graph exists under `urn:ckp:<segment>/`. Verified to discriminate
-- with zero false positives and zero false negatives across three benches with
-- different histories: ckone (demo has 0 graphs -> TRUE), ckdev (demo has 3
-- graphs from when it genuinely ran as demo -> false), pgck.localhost (init's
-- demo pair TRUE, the operator's own pgck pair false).

CREATE OR REPLACE FUNCTION ckp.fleet_adoptions(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_rows jsonb;
  v_bad  int;
  v_orph int;
BEGIN
  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'intoProject', row->>'adopts'), '[]'::jsonb),
         COALESCE(sum(CASE WHEN (row->>'malformed')::boolean THEN 1 ELSE 0 END), 0),
         COALESCE(sum(CASE WHEN (row->>'orphaned')::boolean  THEN 1 ELSE 0 END), 0)
    INTO v_rows, v_bad, v_orph
  FROM (
    SELECT jsonb_build_object(
      'adoption',   a.id,
      'intoProject', a.body->>(N||'intoProject'),
      'adopts',      a.body->>(N||'adopts'),
      'sealedBy',    a.body->>(N||'createdBy'),
      'graphQuads',  (SELECT count(*) FROM pgrdf._pgrdf_quads q
                        JOIN pgrdf._pgrdf_graphs g ON g.graph_id = q.graph_id
                       WHERE g.iri = a.body->>(N||'adopts') AND NOT q.is_inferred),
      'malformed',   NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q2
                        JOIN pgrdf._pgrdf_graphs g2 ON g2.graph_id = q2.graph_id
                       WHERE g2.iri = a.body->>(N||'adopts') AND NOT q2.is_inferred),
      -- 0.4.110: the OTHER half of malformed. The adopts IRI can name a real
      -- module while intoProject names a project with no graphs at all — the
      -- adoption is then sealed, judged, stamped and reachable by nobody.
      -- All four intoProject spellings reduce to the same bare segment
      -- (urn:ckp:<p>, urn:ckp:<p>/kernel/ck, urn:ckp:project:<p>,
      -- urn:ckp:project/<p>) — the same set ckp._adopted_graphs matches on.
      'orphaned',    NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_graphs g3
                       WHERE g3.iri LIKE 'urn:ckp:'
                         || regexp_replace(
                              regexp_replace(a.body->>(N||'intoProject'), '^urn:ckp:project[:/]', ''),
                              '^(urn:ckp:)?([^/]+)(/.*)?$', '\2')
                         || '/%'),
      'structuralPin', (SELECT p.structural_digest FROM ckp.adoption_pins p
                         WHERE p.graph_iri = a.body->>(N||'adopts'))) AS row
    FROM ckp.instances a
    WHERE a.body->>'type' = N||'Adoption'
      AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                       WHERE s.body->>'type' = N||'Supersession'
                         AND s.body->>(N||'supersedes') = a.body->>'@id')
  ) sub;
  RETURN jsonb_build_object('ok', true,
    'adoptions', v_rows,
    'malformedCount', v_bad,
    'orphanedCount', v_orph,
    'note', 'malformed:true = the adopts IRI names NO non-empty graph in this store — a judged Adoption composing NOTHING (module-IRI-is-graph-IRI; the namespace-instead-of-graph and blank-adopts classes). The cure is Supersession + a fresh Adoption naming the module GRAPH IRI. Per-kernel enforcement of this exists as the adopts-resolves obligation, adopted by agreement. orphaned:true = the MODULE resolves but the intoProject names a project with NO graphs in this store — the module is loaded and the adoption is unreachable by any composed surface, so the kernel that was configured cannot use the law that was shipped. Neither flag gates a seal (B4: a report may be wrong cheaply, a gate may not); both are the census telling the truth about an install.',
    'completeness', jsonb_build_object(
      'verdict', 'complete for sealed, unsuperseded Adoptions in this store',
      'counters', ckp._engine_counters()));
END;
$function$
;
