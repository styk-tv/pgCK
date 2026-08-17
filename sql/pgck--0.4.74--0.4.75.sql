-- pgck--0.4.74--0.4.75.sql — THE AUTHORITY READ MATCHES THE IDENTITY IT IS GIVEN.
--
-- MEASURED DEFECT (PASS-31, 2026-08-17, live bench, immediately after 0.4.74):
--
--   authority.mine (door)  -> identity: "d6b635a3-5a5b-4fc2-a86e-e1573dbcc896"   BARE uuid
--   sealed Membership      -> memberIs: "urn:ckp:participant:c45b14bb-…"          FULL urn
--
--   ckp.authority_of('c45b14bb-8852-49f0-bd14-8b37a649d820')            -> memberships 0, grants 0
--   ckp.authority_of('urn:ckp:participant:c45b14bb-8852-49f0-bd14-…')   -> memberships 1, grants 2
--
--   Same identity, two spellings, and the equality test never fires. So through
--   the door authority.mine returned EMPTY FOR EVERY CALLER, and 0.4.74's repair
--   of the Role->grant[]->Grant edge — necessary — was not sufficient. Two
--   independent breaks stacked, and fixing only the visible one still yields a
--   confident zero, which is the failure mode this substrate exists to retire.
--
-- FIX: resolve the identity to BOTH candidate spellings and match either.
--
--   given 'urn:ckp:participant:X'  ->  { 'urn:ckp:participant:X', 'X' }
--   given 'X'                      ->  { 'urn:ckp:participant:X', 'X' }
--
-- WHY BOTH, rather than normalising to one: the store is not proven uniform.
-- Every Membership measured today carries the urn: form, but that is 1 record,
-- and asserting uniformity from n=1 is the prior-without-a-count defect. Matching
-- both is correct whichever way the substrate later settles, and it does not
-- prejudge the broader question — whether ckp.requester should carry the
-- canonical form everywhere — which touches every reader, not just this one, and
-- is NOT decided here.
--
-- ENVELOPE: `identity` is unchanged and still echoes what the caller was given,
-- so no consumer pin breaks. `identityCanonical` is ADDED, carrying the urn:
-- form, so a client can render and compare one spelling without normalising
-- identity itself — normalisation in a consumer is the same class as a
-- client-side delegate flag and is refused by design.
--
-- NEGATIVE CONTROL ships with it: sql/test/s69_authority_join.sql §6 asserts the
-- bare and urn: forms of ONE participant return the IDENTICAL chain, and that a
-- uuid belonging to nobody still returns empty under both spellings — so the
-- widened match cannot manufacture a chain.

CREATE OR REPLACE FUNCTION ckp.authority_of(p_participant text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'https://conceptkernel.org/ontology/v3.11/core#';
  P      text := 'urn:ckp:participant:';
  v_in   text := COALESCE(p_participant, NULLIF(current_setting('ckp.requester', true), ''));
  v_anon boolean := v_in IS NULL;
  v_urn  text; v_bare text; v_forms text[];
  v_mem jsonb; v_grants jsonb;
BEGIN
  IF v_anon THEN
    RETURN jsonb_build_object('ok', true, 'identity', NULL, 'identityCanonical', NULL,
      'tier', 'anonymous', 'memberships', '[]'::jsonb, 'grants', '[]'::jsonb,
      'note', 'anonymous tier: no verified identity, so no authority chain exists to resolve. '||
              'Transport grants (events-only, no publish) are minted at admission and are not '||
              'readable here — see SPEC.PGCK.IDENTITY-PATH.');
  END IF;

  -- Both spellings of one identity. The door supplies the bare uuid; sealed
  -- Memberships carry the urn: form. Neither is normalised away, because which
  -- one is canonical at the REQUESTER is a separate question from which one is
  -- stored, and this function must answer correctly under either answer.
  IF v_in LIKE P||'%' THEN
    v_urn := v_in;  v_bare := substring(v_in from length(P)+1);
  ELSE
    v_bare := v_in; v_urn := P||v_in;
  END IF;
  v_forms := ARRAY[v_urn, v_bare];

  SELECT jsonb_agg(jsonb_build_object('membership', m.body->>'@id',
                                      'memberOf',  m.body->>(N||'memberOf'),
                                      'holdsRole', m.body->>(N||'holdsRole')))
    INTO v_mem
  FROM ckp.instances m
  WHERE m.body->>'type' = N||'Membership'
    AND m.body->>(N||'memberIs') = ANY(v_forms);

  WITH held AS (
    SELECT r.body AS rbody, r.body->>'@id' AS role_iri
      FROM ckp.instances r
     WHERE r.body->>'type' = N||'Role'
       AND r.body->>'@id' IN (SELECT m.body->>(N||'holdsRole')
                                FROM ckp.instances m
                               WHERE m.body->>'type' = N||'Membership'
                                 AND m.body->>(N||'memberIs') = ANY(v_forms))
  ),
  via_role AS (
    SELECT g.body AS gbody, h.role_iri
      FROM held h
      CROSS JOIN LATERAL jsonb_array_elements_text(
             CASE jsonb_typeof(h.rbody->(N||'grant'))
               WHEN 'array'  THEN h.rbody->(N||'grant')
               WHEN 'string' THEN jsonb_build_array(h.rbody->(N||'grant'))
               ELSE '[]'::jsonb
             END) AS gi(iri)
      JOIN ckp.instances g
        ON g.body->>'@id' = gi.iri
       AND g.body->>'type' = N||'Grant'
  ),
  via_granted AS (
    SELECT g.body AS gbody, h.role_iri
      FROM held h
      JOIN ckp.instances g
        ON g.body->>'type' = N||'Grant'
       AND g.body->>(N||'grantedVia') = h.role_iri
  ),
  merged AS (
    SELECT DISTINCT ON (gbody->>'@id') gbody, role_iri
      FROM (SELECT * FROM via_role UNION ALL SELECT * FROM via_granted) u
     ORDER BY gbody->>'@id', role_iri
  )
  SELECT jsonb_agg(jsonb_build_object(
           'grant',      gbody->>'@id',
           'permTarget', gbody->>(N||'permTarget'),
           'permAction', gbody->>(N||'permAction'),
           'permDomain', gbody->>(N||'permDomain'),
           'permission', gbody->>(N||'permission'),
           'viaRole',    role_iri))
    INTO v_grants
    FROM merged;

  RETURN jsonb_build_object('ok', true,
    'identity', v_in, 'identityCanonical', v_urn, 'tier', 'verified',
    'memberships', COALESCE(v_mem, '[]'::jsonb),
    'grants', COALESCE(v_grants, '[]'::jsonb),
    'note', CASE
      WHEN v_mem IS NULL
        THEN 'no sealed Membership for this identity — the authority chain is EMPTY, which is '||
             'not the same as unchecked. Both the bare and urn:ckp:participant: spellings were '||
             'tried. Dispatch is currently governed by the transport tier and the role floor, '||
             'not by this chain.'
      WHEN v_grants IS NULL
        THEN 'this identity holds a Membership and a Role, and that Role reaches NO Grant. '||
             'The chain resolves and TERMINATES — reported as a result, not as silence.'
      ELSE NULL END);
END;
$function$;
