-- pgck--0.4.73--0.4.74.sql — THE AUTHORITY READ JOINS THE EDGE THE DATA ACTUALLY HAS.
--
-- MEASURED DEFECT (PASS-31, 2026-08-17, epoch 16, on the live bench):
--
--   ckp.authority_of('urn:ckp:participant:c45b14bb-…') returned
--     { ok: true, tier: 'verified', memberships: [1 row], grants: [] }
--
--   while the SAME participant demonstrably reaches TWO Grants:
--     govern @ urn:ckp:ck-dev/organ/ck   (grant-1786645454254404000)
--     write  @ urn:ckp:ck-dev/organ/data (grant-1786645454989498000)
--
-- ROOT CAUSE — the reader joins predicates the emission does not write:
--
--   reader (since 0.4.38)          sealed data (measured)
--   ---------------------          ----------------------
--   Grant -> core#grantedVia -> Role   Role -> core#grant[] -> Grant
--   Grant -> core#permission           Grant -> core#permAction (+ permDomain)
--
--   Both the EDGE DIRECTION and the PERMISSION KEY are wrong, so the subquery
--   matches nothing and the aggregate is NULL, coalesced to []. The reply is
--   ok:true with an empty list — a CONFIDENT ZERO. A caller reads "checked,
--   found no grants"; the truth is "joined on a predicate nothing carries".
--   This is ck-dev's "decorative authority reads" measured end to end, and it
--   is the R-1 split this repo's own SECURITY spec §3.1 already named:
--   "vocabulary declaring one thing, reader joining another".
--
-- FIX: traverse Role -> core#grant[] -> Grant and report permAction/permDomain.
-- The grantedVia direction is kept as a UNION branch so any legacy or future
-- record carrying it still resolves — the reader widens, the emission is not
-- asked to change (R-1: the data is already emitted; the READER was wrong).
--
-- NEGATIVE CONTROL ships with it: sql/test/s69_authority_join.sql asserts a
-- participant WITHOUT a chain still returns grants=[] , so a non-empty result
-- cannot be produced by the fix alone.

CREATE OR REPLACE FUNCTION ckp.authority_of(p_participant text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_who text := COALESCE(p_participant, NULLIF(current_setting('ckp.requester', true), ''));
  v_anon boolean := v_who IS NULL;
  v_mem jsonb; v_grants jsonb;
BEGIN
  -- Anonymous is a TIER, not an identity: nothing durable accretes to it
  -- (persona spec PR1), so it has no chain to traverse and saying so is the
  -- answer — not an empty list that reads like "checked and found none".
  IF v_anon THEN
    RETURN jsonb_build_object('ok', true, 'identity', NULL, 'tier', 'anonymous',
      'memberships', '[]'::jsonb, 'grants', '[]'::jsonb,
      'note', 'anonymous tier: no verified identity, so no authority chain exists to resolve. '||
              'Transport grants (events-only, no publish) are minted at admission and are not '||
              'readable here — see SPEC.PGCK.IDENTITY-PATH.');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('membership', m.body->>'@id',
                                      'memberOf',  m.body->>(N||'memberOf'),
                                      'holdsRole', m.body->>(N||'holdsRole')))
    INTO v_mem
  FROM ckp.instances m
  WHERE m.body->>'type' = N||'Membership' AND m.body->>(N||'memberIs') = v_who;

  -- The roles this identity holds, resolved once and reused by both branches.
  WITH held AS (
    SELECT r.body AS rbody, r.body->>'@id' AS role_iri
      FROM ckp.instances r
     WHERE r.body->>'type' = N||'Role'
       AND r.body->>'@id' IN (SELECT m.body->>(N||'holdsRole')
                                FROM ckp.instances m
                               WHERE m.body->>'type' = N||'Membership'
                                 AND m.body->>(N||'memberIs') = v_who)
  ),
  -- PRIMARY: Role -> core#grant[] -> Grant. core#grant is emitted as an ARRAY
  -- when a role holds several and MAY appear as a bare string for one, so both
  -- shapes are normalised rather than assumed.
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
  -- LEGACY/FORWARD: Grant -> core#grantedVia -> Role. Retained so a record
  -- carrying the other direction is not silently dropped by this repair.
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
           -- kept for readers pinned to the old key; NULL on every sealed
           -- Grant measured to date, and reported rather than hidden.
           'permission', gbody->>(N||'permission'),
           'viaRole',    role_iri))
    INTO v_grants
    FROM merged;

  RETURN jsonb_build_object('ok', true, 'identity', v_who, 'tier', 'verified',
    'memberships', COALESCE(v_mem, '[]'::jsonb),
    'grants', COALESCE(v_grants, '[]'::jsonb),
    'note', CASE
      WHEN v_mem IS NULL
        THEN 'no sealed Membership for this identity — the authority chain is EMPTY, which is '||
             'not the same as unchecked. Dispatch is currently governed by the transport tier '||
             'and the role floor, not by this chain.'
      WHEN v_grants IS NULL
        THEN 'this identity holds a Membership and a Role, and that Role reaches NO Grant. '||
             'The chain resolves and terminates — reported as a result, not as silence.'
      ELSE NULL END);
END;
$function$;
