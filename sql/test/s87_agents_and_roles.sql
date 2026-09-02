-- s87_agents_and_roles.sql — THE LAW GAINS ITS READERS (0.4.107).
--
-- onBehalfOf and Role/Grant/Membership were declared since the root shipped,
-- read by nothing. C-7: the seal derives onBehalfOf from the trusted ingress
-- (absence is the signal; payload claims strip). C-6: Memberships narrow
-- propose/vote/apply per-action; the owner is never narrowed; an unmembered
-- project imposes nothing; Memberships are the owner's to seal.
\set ON_ERROR_STOP 1

DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        b jsonb; r jsonb; refused boolean := false; msg text;
BEGIN
  -- (a) agent seal carries the stamp; direct seal does not; forged claim strips.
  PERFORM set_config('ckp.requester','svc:s87-agent',true);
  PERFORM set_config('ckp.on_behalf_of','s87-human',true);
  PERFORM ckp.seal('s87-agent', jsonb_build_object('type',C||'Vote','@id','ckp://Vote#s87-agent',
    C||'about','ckp://Proposal#s87-x', C||'voteValue','approve'));
  SELECT body INTO b FROM ckp.instances WHERE id='s87-agent';
  IF b->>(C||'onBehalfOf') IS DISTINCT FROM 'urn:ckp:participant:s87-human' THEN
    RAISE EXCEPTION 's87 (a) FAIL — agent seal did not stamp onBehalfOf (got %)', COALESCE(b->>(C||'onBehalfOf'),'nothing'); END IF;
  PERFORM set_config('ckp.on_behalf_of','',true);
  PERFORM ckp.seal('s87-direct', jsonb_build_object('type',C||'Vote','@id','ckp://Vote#s87-direct',
    C||'about','ckp://Proposal#s87-x', C||'voteValue','approve',
    C||'onBehalfOf','urn:ckp:participant:s87-victim'));
  SELECT body INTO b FROM ckp.instances WHERE id='s87-direct';
  IF b ? (C||'onBehalfOf') THEN
    RAISE EXCEPTION 's87 (a) FAIL — a direct seal carries onBehalfOf (forged claim sealed)'; END IF;
  RAISE NOTICE 's87 (a) PASS — agent stamped, direct clean, payload claim stripped';

  -- (b) role narrowing end to end.
  DELETE FROM ckp.instances WHERE id LIKE 's87-r-%';
  INSERT INTO ckp.instances(id, body) VALUES
    ('s87-r-proj', jsonb_build_object('@id','urn:ckp:project:s87r','type',C||'Project',
       'http://www.w3.org/2000/01/rdf-schema#label','s87r', C||'ownedBy','urn:ckp:participant:s87-owner')),
    ('s87-r-grant', jsonb_build_object('@id','ckp://Grant#s87-propose','type',C||'Grant',
       C||'permDomain','governance', C||'permAction','propose', C||'permTarget','urn:ckp:s87r/organ/ck')),
    ('s87-r-role', jsonb_build_object('@id','ckp://Role#s87-proposer','type',C||'Role',
       'http://www.w3.org/2000/01/rdf-schema#label','proposer', C||'grant','ckp://Grant#s87-propose')),
    ('s87-r-mem', jsonb_build_object('@id','ckp://Membership#s87-m1','type',C||'Membership',
       C||'memberIs','urn:ckp:participant:s87-member', C||'memberOf','urn:ckp:project:s87r',
       C||'holdsRole','ckp://Role#s87-proposer'));
  PERFORM set_config('ckp.requester','s87-stranger',true);
  r := ckp.propose_change('s87r', jsonb_build_object('op','add_class','detail',jsonb_build_object('class','urn:ckp:s87r/type/X')));
  IF r->>'error' IS DISTINCT FROM 'role_required' OR r->>'sqlstate' IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 's87 (b) FAIL — stranger got %/% instead of role_required/42501', COALESCE(r->>'error','ok'), COALESCE(r->>'sqlstate','-'); END IF;
  PERFORM set_config('ckp.requester','s87-member',true);
  r := ckp.propose_change('s87r', jsonb_build_object('op','add_class','detail',jsonb_build_object('class','urn:ckp:s87r/type/X')));
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's87 (b) FAIL — the granted member was refused: %', r->>'error'; END IF;
  b := ckp.vote(jsonb_build_object('about', r->>'proposal_iri', 'value','approve'));
  IF b->>'error' IS DISTINCT FROM 'role_required' THEN
    RAISE EXCEPTION 's87 (b) FAIL — a propose-only member voted (got %): narrowing is not per-action', COALESCE(b->>'error','ok'); END IF;
  PERFORM set_config('ckp.requester','s87-owner',true);
  b := ckp.propose_change('s87r', jsonb_build_object('op','add_class','detail',jsonb_build_object('class','urn:ckp:s87r/type/Y')));
  IF (b->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's87 (b) FAIL — the owner was narrowed by their own roles: %', b->>'error'; END IF;
  RAISE NOTICE 's87 (b) PASS — stranger refused role_required/42501; member passes only their granted action; owner never narrowed';

  -- (c) owner-settable: a stranger's Membership seal refuses.
  PERFORM set_config('ckp.requester','s87-stranger',true);
  BEGIN
    PERFORM ckp.seal('s87-r-evil', jsonb_build_object('@id','ckp://Membership#s87-evil','type',C||'Membership',
       C||'memberIs','urn:ckp:participant:s87-stranger', C||'memberOf','urn:ckp:project:s87r',
       C||'holdsRole','ckp://Role#s87-proposer'));
  EXCEPTION WHEN OTHERS THEN refused := true; msg := SQLERRM;
  END;
  IF NOT refused OR position('not_owner' in msg) = 0 THEN
    RAISE EXCEPTION 's87 (c) FAIL — a stranger sealed a Membership into an owned project (%)', COALESCE(left(msg,60),'sealed clean'); END IF;
  RAISE NOTICE 's87 (c) PASS — Memberships are the owner''s to seal (%…)', left(msg,40);

  DELETE FROM ckp.instances WHERE id LIKE 's87-%' OR body->>'@id' LIKE '%s87r%';
END $$;

\echo 's87 PASS — onBehalfOf server-derived with absence as the signal; roles narrow per-action and only the owner binds them'
