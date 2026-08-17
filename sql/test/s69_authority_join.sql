-- s69_authority_join.sql — THE AUTHORITY READ RESOLVES THE EDGE THE DATA HAS (0.4.74).
--
--   (1) CHAIN RESOLVES: a sealed Membership -> Role -> core#grant[] -> Grant
--       makes ckp.authority_of return a NON-EMPTY grants list carrying
--       permAction / permDomain / permTarget and the role it came through.
--       Before 0.4.74 this returned [] with ok:true — a confident zero.
--   (2) NEGATIVE CONTROL, no chain: an identity with no Membership returns
--       grants=[] AND the "chain is EMPTY" note. The fix cannot manufacture
--       authority out of nothing.
--   (3) NEGATIVE CONTROL, chain terminates: an identity holding a Role that
--       reaches NO Grant returns grants=[] and says the chain RESOLVED AND
--       TERMINATED — reported as a result, never as silence (A4/A6).
--   (4) NEGATIVE CONTROL, isolation: participant A's grants never leak into
--       participant B's answer.
--   (5) ANONYMOUS is a TIER: no participant resolves to tier 'anonymous'
--       with a note, not to an empty list that reads like "checked".
--   (6) IDENTITY FORM (0.4.75): the BARE uuid and the urn:ckp:participant:
--       spelling of ONE identity return the IDENTICAL chain — the door supplies
--       the bare form while memberIs stores the urn: form, and before 0.4.75
--       the equality test never fired, so authority.mine returned empty for
--       EVERY caller even with the 0.4.74 edge repair in place. Its negative
--       control: a uuid belonging to nobody stays empty under BOTH spellings,
--       so the widened match cannot manufacture a chain.
--
-- Measured defect this pins (PASS-31, 2026-08-17, live bench, epoch 16):
--   authority_of('urn:ckp:participant:c45b14bb-…') -> memberships:[1], grants:[]
--   while the same participant reaches govern@ck-dev/organ/ck and
--   write@ck-dev/organ/data. Reader joined Grant->grantedVia->Role and read
--   core#permission; the data carries Role->grant[]->Grant and core#permAction.
--   Present since 0.4.38.
--
-- Run (booted by the smoke): psql … < s69_authority_join.sql

\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SET ckp.project = 's69-test';

DO $$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  pA text := 'urn:ckp:participant:s69-aaaaaaaa-0000-0000-0000-00000000000a';
  pB text := 'urn:ckp:participant:s69-bbbbbbbb-0000-0000-0000-00000000000b';
  pC text := 'urn:ckp:participant:s69-cccccccc-0000-0000-0000-00000000000c';
  g1 text; g2 text; rA text; rC text;
  res jsonb; grants jsonb; acts text[];
BEGIN
  ----------------------------------------------------------------------------
  -- fixture: two Grants, a Role that reaches both, a Membership binding pA.
  ----------------------------------------------------------------------------
  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Grant',
           'body', jsonb_build_object(
             'permAction','govern', 'permDomain','governance',
             'permTarget','urn:ckp:s69-test/organ/ck')));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (0): seal Grant #1: %', res; END IF;
  g1 := COALESCE(res->>'urn', res->>'id');

  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Grant',
           'body', jsonb_build_object(
             'permAction','write', 'permDomain','instance',
             'permTarget','urn:ckp:s69-test/organ/data')));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (0): seal Grant #2: %', res; END IF;
  g2 := COALESCE(res->>'urn', res->>'id');

  -- core#grant is an ARRAY on the Role — the edge the reader must traverse.
  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Role',
           'body', jsonb_build_object(
             'label','s69 operator',
             'grant', jsonb_build_array(g1, g2))));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (0): seal Role: %', res; END IF;
  rA := COALESCE(res->>'urn', res->>'id');

  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Membership',
           'body', jsonb_build_object(
             'memberIs', pA, 'memberOf','urn:ckp:project:s69-test',
             'holdsRole', rA)));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (0): seal Membership pA: %', res; END IF;

  ----------------------------------------------------------------------------
  -- (1) the chain resolves and carries the RIGHT keys.
  ----------------------------------------------------------------------------
  res := ckp.authority_of(pA);
  grants := res->'grants';
  IF jsonb_array_length(COALESCE(grants,'[]'::jsonb)) <> 2 THEN
    RAISE EXCEPTION 's69 FAIL (1): expected 2 grants for pA, got %. '||
      'This is the 0.4.38 defect: reader joined grantedVia/permission, data '||
      'carries grant[]/permAction. full=%', jsonb_array_length(COALESCE(grants,'[]'::jsonb)), res;
  END IF;

  SELECT array_agg(e->>'permAction' ORDER BY e->>'permAction')
    INTO acts FROM jsonb_array_elements(grants) e;
  IF acts IS DISTINCT FROM ARRAY['govern','write'] THEN
    RAISE EXCEPTION 's69 FAIL (1): permAction not carried, got %. full=%', acts, res; END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(grants) e
                  WHERE e->>'permTarget' = 'urn:ckp:s69-test/organ/ck') THEN
    RAISE EXCEPTION 's69 FAIL (1): permTarget not carried. full=%', res; END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(grants) e
                  WHERE e->>'viaRole' = rA) THEN
    RAISE EXCEPTION 's69 FAIL (1): viaRole not reported — a grant must name the '||
      'role it was reached through, or the chain is unauditable. full=%', res; END IF;

  ----------------------------------------------------------------------------
  -- (2) NEGATIVE CONTROL: no Membership at all -> empty, and SAYS SO.
  ----------------------------------------------------------------------------
  res := ckp.authority_of(pB);
  IF jsonb_array_length(COALESCE(res->'grants','[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 's69 FAIL (2): pB has no chain but got grants: %', res; END IF;
  IF COALESCE(res->>'note','') NOT LIKE '%chain is EMPTY%' THEN
    RAISE EXCEPTION 's69 FAIL (2): empty result must NAME itself, not just be empty. full=%', res; END IF;

  ----------------------------------------------------------------------------
  -- (3) NEGATIVE CONTROL: chain resolves then TERMINATES (Role, zero Grants).
  --     An empty list here means something different from (2) and must say so.
  ----------------------------------------------------------------------------
  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Role', 'body', jsonb_build_object('label','s69 grantless')));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (3): seal grantless Role: %', res; END IF;
  rC := COALESCE(res->>'urn', res->>'id');

  res := ckp.dispatch('instance.create', jsonb_build_object(
           'type', N||'Membership',
           'body', jsonb_build_object('memberIs', pC,
             'memberOf','urn:ckp:project:s69-test', 'holdsRole', rC)));
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 's69 FAIL (3): seal Membership pC: %', res; END IF;

  res := ckp.authority_of(pC);
  IF jsonb_array_length(COALESCE(res->'grants','[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 's69 FAIL (3): grantless role produced grants: %', res; END IF;
  IF jsonb_array_length(COALESCE(res->'memberships','[]'::jsonb)) <> 1 THEN
    RAISE EXCEPTION 's69 FAIL (3): pC membership did not resolve: %', res; END IF;
  IF COALESCE(res->>'note','') NOT LIKE '%TERMINAT%' THEN
    RAISE EXCEPTION 's69 FAIL (3): a resolved-but-terminating chain must be '||
      'distinguishable from an absent one. full=%', res; END IF;

  ----------------------------------------------------------------------------
  -- (4) NEGATIVE CONTROL: isolation — pA's grants stay pA's.
  ----------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(
               COALESCE(ckp.authority_of(pC)->'grants','[]'::jsonb)) e
              WHERE e->>'grant' IN (g1, g2)) THEN
    RAISE EXCEPTION 's69 FAIL (4): pA grants leaked into pC'; END IF;

  ----------------------------------------------------------------------------
  -- (5) anonymous is a TIER, not an empty list.
  ----------------------------------------------------------------------------
  PERFORM set_config('ckp.requester', '', true);
  res := ckp.authority_of(NULL);
  IF (res->>'tier') IS DISTINCT FROM 'anonymous' THEN
    RAISE EXCEPTION 's69 FAIL (5): anonymous must report its TIER, got %', res; END IF;
  IF COALESCE(res->>'note','') = '' THEN
    RAISE EXCEPTION 's69 FAIL (5): anonymous must explain itself, not return a bare []'; END IF;

  ----------------------------------------------------------------------------
  -- (6) IDENTITY FORM: one identity, two spellings, one chain (0.4.75).
  --     The door supplies the bare uuid; memberIs stores urn:ckp:participant:.
  ----------------------------------------------------------------------------
  DECLARE
    bare  text := replace(pA, 'urn:ckp:participant:', '');
    r_urn jsonb := ckp.authority_of(pA);
    r_bar jsonb := ckp.authority_of(bare);
  BEGIN
    IF jsonb_array_length(r_bar->'grants') <> jsonb_array_length(r_urn->'grants') THEN
      RAISE EXCEPTION 's69 FAIL (6): bare form resolved % grants, urn form resolved % — '||
        'one identity must not have two answers. bare=% urn=%',
        jsonb_array_length(r_bar->'grants'), jsonb_array_length(r_urn->'grants'), r_bar, r_urn;
    END IF;
    IF jsonb_array_length(r_bar->'memberships') <> 1 THEN
      RAISE EXCEPTION 's69 FAIL (6): bare form lost the Membership — this is the pre-0.4.75 '||
        'defect where authority.mine returned empty for every door caller. full=%', r_bar;
    END IF;
    IF (r_bar->>'identityCanonical') IS DISTINCT FROM pA THEN
      RAISE EXCEPTION 's69 FAIL (6): identityCanonical must carry the urn: form regardless of '||
        'which spelling was supplied, got %', r_bar->>'identityCanonical';
    END IF;
    IF (r_bar->>'identity') IS DISTINCT FROM bare THEN
      RAISE EXCEPTION 's69 FAIL (6): identity must echo what the caller supplied, got %',
        r_bar->>'identity';
    END IF;

    -- NEGATIVE CONTROL for (6): a uuid belonging to nobody stays empty under
    -- BOTH spellings. The widened match must not manufacture a chain.
    IF jsonb_array_length(ckp.authority_of('s69-nobody-0000-0000-0000-000000000000')->'grants') <> 0
    OR jsonb_array_length(ckp.authority_of('urn:ckp:participant:s69-nobody-0000-0000-0000-000000000000')->'grants') <> 0 THEN
      RAISE EXCEPTION 's69 FAIL (6-NC): widened identity match manufactured a chain for a '||
        'participant that does not exist';
    END IF;
  END;

  RAISE NOTICE 's69 PASS — authority chain resolves (2 grants via role %), both identity spellings agree, and all five negative controls hold.', rA;
END $$;
