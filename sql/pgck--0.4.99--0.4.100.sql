-- pgck 0.4.99 -> 0.4.100
--
-- E-2 — THE ROSTER RECONCILES ALL THREE POPULATIONS.
--
-- Raised by pgRDF's v0.6.35-to-PGCK-1 §4, and the interesting part is that they
-- could not answer their own question from their side. They asked why they have
-- no urn:ckp:pgrdf/instances graph when twenty-three other kernels do. The
-- answer, measured here: pgrdf is in NEITHER the GUC roster NOR the ledger. It
-- was never germinated, and it cannot germinate, because reaching the door
-- requires being rostered and the roster is built from seals. That is the
-- bootstrap paradox verbatim, and the cure is one operator seed entry rather
-- than any change to the projection.
--
-- None of that was readable anywhere. ckp.roster() reported guc, ledger, union
-- and ledgerOnly — "sealed but never configured" — and had no report at all for
-- the other two populations:
--
--   gucOnly  rostered by hand and never sealed. Addressable, but nothing in the
--            ledger says it exists; germination is its open next act.
--   ghosts   graphs under a kernel-shaped IRI with NO sealed ckp:Kernel behind
--            them. Measured live on ckdev: `demo` holds three graphs INCLUDING A
--            COMPOSED SURFACE and appears in neither roster half — a kernel that
--            can JUDGE and cannot be reached, owned, or re-germinated. Nothing
--            refuses it because nothing can get to it, and nothing reported it.
--
-- A name absent from all three was never germinated. That sentence is now
-- answerable by reading one verb instead of by asking the substrate's owner.

CREATE OR REPLACE FUNCTION ckp.roster()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  WITH guc AS (
    SELECT COALESCE(array_agg(DISTINCT btrim(k) ORDER BY btrim(k))
             FILTER (WHERE btrim(k) <> ''), ARRAY[]::text[]) AS names
    FROM unnest(string_to_array(COALESCE(current_setting('pgck.kernels', true), ''), ',')) k
  ), led AS (SELECT ckp._ledger_kernels() AS names)
  SELECT jsonb_build_object(
    'guc',    to_jsonb((SELECT names FROM guc)),
    'ledger', to_jsonb((SELECT names FROM led)),
    'union',  to_jsonb((SELECT ARRAY(SELECT DISTINCT unnest((SELECT names FROM guc) || (SELECT names FROM led)) ORDER BY 1))),
    'ledgerOnly', to_jsonb((SELECT ARRAY(SELECT unnest((SELECT names FROM led))
                                          EXCEPT SELECT unnest((SELECT names FROM guc)) ORDER BY 1))),
    -- 0.4.100 (E-2, raised by pgRDF's §4). ledgerOnly answered "sealed but never
    -- configured". The other two populations had no report at all, and pgRDF
    -- could not answer their own question from their side because of it: they
    -- asked why they have no /instances graph, and the answer — pgrdf is in
    -- NEITHER the GUC nor the ledger, so it was never germinated and cannot
    -- germinate because reaching the door requires being rostered — was
    -- unreadable anywhere.
    --
    -- gucOnly: rostered by hand and never sealed. Addressable, but nothing in
    -- the ledger says it exists; germination is its open next act.
    -- ghosts: graphs under a kernel-shaped IRI with NO sealed ckp:Kernel behind
    -- them. Measured live: `demo` holds three graphs including a COMPOSED
    -- SURFACE and appears in neither roster half — a kernel that can judge and
    -- cannot be reached, owned, or re-germinated. Nothing refuses it because
    -- nothing can get to it, and until now nothing reported it either.
    'gucOnly', to_jsonb((SELECT ARRAY(SELECT unnest((SELECT names FROM guc))
                                       EXCEPT SELECT unnest((SELECT names FROM led)) ORDER BY 1))),
    'ghosts', to_jsonb((SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::text[]) FROM (
                          SELECT DISTINCT substring(g.iri from '^urn:ckp:([a-z0-9-]+)/') AS k
                            FROM pgrdf._pgrdf_graphs g
                           WHERE g.iri LIKE 'urn:ckp:%/%'
                             AND substring(g.iri from '^urn:ckp:([a-z0-9-]+)/') IS NOT NULL
                          EXCEPT SELECT unnest((SELECT names FROM led))) x)),
    'refreshSeconds', 5,
    'note', 'the grant set the callout mints from is guc UNION ledger, refreshed ~5s by the '
            'bgworker tick — germination IS existence. This is what the SUBSTRATE holds; the '
            'broker mints per CONNECT and a LIVE socket keeps what it was minted with, so a '
            'name appearing here reaches a NEW connection, not an existing one. Reconnect '
            'first, then diagnose the door. Authority: ruling-1788038690953958000 — read the '
            'ruling, do not rely on this paraphrase. THREE POPULATIONS, and a name absent from '
            'all three was never germinated and cannot germinate until seeded: ledgerOnly is '
            'sealed-but-unconfigured, gucOnly is configured-but-unsealed, ghosts hold graphs '
            'with no sealed Kernel at all.');
$function$
;
