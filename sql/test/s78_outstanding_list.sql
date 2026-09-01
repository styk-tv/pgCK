-- s78_outstanding_list.sql — THE SIX PROMISES, EACH WITH THE CASE THAT WOULD FAIL (0.4.90).
--
-- WHY THIS EXISTS. 0.4.89's scope was declared to a counterparty as six items and
-- shipped one, because a second finding took the version number in between. This
-- file is the gate for the rest. Every claim below ships with the negative half,
-- because a check that cannot fail the thing it claims is not a check.
--
--   (a) §3 id-form  — every form the substrate EMITS resolves…
--   (b) §3 control  — …and an id that resolves to nothing REFUSES rather than
--                     returning ok:true with instance:null. The confident absence
--                     is the defect; a bare "it resolves" test would not see it.
--   (c) §2 epoch    — a virgin kernel's first bump is 1, not 2. The phantom epoch
--                     was pure convention drift between the read and write planes.
--   (d) §2 control  — an ALREADY-ADVANCED kernel is not reset by the seed.
--   (e) Q-1 roster  — a kernel sealed and in NO GUC appears in ledgerOnly…
--   (f) Q-1 control — …a RETIRED kernel and a NON-CANONICAL spelling do NOT, or
--                     the union would grant on names the door cannot route.
--   (g) Q-2/Q-3     — registryDigest is stable and plane is NULL where mixed. A
--                     confident plane on a mixed sqlstate is the findings:[null]
--                     defect wearing a different hat.
--   (h) dup adopt   — a module adopted twice composes once.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  r jsonb; d1 text; d2 text; a text[];
BEGIN
  -- fixtures ---------------------------------------------------------------
  INSERT INTO ckp.instances(id,body) VALUES
    ('s78-vote', jsonb_build_object('@id','ckp://Vote#s78-vote','type',N||'Vote')),
    ('urn:ckp:s78sealed/kernel', jsonb_build_object('@id','urn:ckp:s78sealed/kernel','type',N||'Kernel')),
    ('urn:ckp:s78retired/kernel', jsonb_build_object('@id','urn:ckp:s78retired/kernel','type',N||'Kernel', N||'retiredAtEpoch', 3)),
    ('urn:ckp:S78Caps/kernel',   jsonb_build_object('@id','urn:ckp:S78Caps/kernel','type',N||'Kernel')),
    ('s78-ad1', jsonb_build_object('@id','ckp://Adoption#s78-ad1','type',N||'Adoption',N||'adopts','urn:ckp:module:s78',N||'intoProject','urn:ckp:s78proj')),
    ('s78-ad2', jsonb_build_object('@id','ckp://Adoption#s78-ad2','type',N||'Adoption',N||'adopts','urn:ckp:module:s78',N||'intoProject','urn:ckp:s78proj'));

  -- (a) every emitted id form resolves --------------------------------------
  IF ckp._query('instance.get', jsonb_build_object('id','s78-vote'))->'instance'->'body'->>'@id'
       IS DISTINCT FROM 'ckp://Vote#s78-vote'
   OR ckp._query('instance.get', jsonb_build_object('id','ckp://Vote#s78-vote'))->'instance'->'body'->>'@id'
       IS DISTINCT FROM 'ckp://Vote#s78-vote'
   OR ckp._query('instance.get', jsonb_build_object('id','urn:ckp:instance:s78-vote'))->'instance'->'body'->>'@id'
       IS DISTINCT FROM 'ckp://Vote#s78-vote' THEN
    RAISE EXCEPTION 's78 FAIL (a): instance.get does not resolve every id form the substrate emits';
  END IF;
  RAISE NOTICE 's78 (a) PASS — bare, ckp:// and urn: forms all resolve';

  -- (b) THE CONTROL: an unresolvable id refuses, never a confident null ------
  r := ckp._query('instance.get', jsonb_build_object('id','ckp://Vote#s78-does-not-exist'));
  IF (r->>'ok')::boolean IS TRUE THEN
    RAISE EXCEPTION 's78 FAIL (b): an id that resolves to NOTHING returned ok:true — a confident absence is worse than a refusal. got %', r;
  END IF;
  IF (r->>'refused')::boolean IS NOT TRUE OR r->>'error' NOT LIKE '%Accepted forms%' THEN
    RAISE EXCEPTION 's78 FAIL (b): refused without naming the accepted forms — a refusal that does not teach is a bare error. got %', r;
  END IF;
  RAISE NOTICE 's78 (b) PASS — unresolvable id refuses and names the forms';

  -- (c) a virgin kernel's first bump is an honest 0 -> 1 ---------------------
  DELETE FROM ckp.kernel_epoch WHERE kernel = 's78virgin';
  IF ckp.bump_epoch('s78virgin') <> 1 THEN
    RAISE EXCEPTION 's78 FAIL (c): first bump on a virgin kernel did not return 1 — the phantom epoch is back';
  END IF;
  RAISE NOTICE 's78 (c) PASS — first apply is 0 -> 1, no phantom';

  -- (d) CONTROL: an advanced kernel is not reset ----------------------------
  INSERT INTO ckp.kernel_epoch(kernel,epoch) VALUES ('s78adv', 7)
    ON CONFLICT (kernel) DO UPDATE SET epoch = 7;
  IF ckp.bump_epoch('s78adv') <> 8 THEN
    RAISE EXCEPTION 's78 FAIL (d): an already-advanced kernel was disturbed by the seed';
  END IF;
  RAISE NOTICE 's78 (d) PASS — advanced kernels untouched';

  -- (e) the ledger half carries a sealed, never-configured kernel -----------
  IF NOT (ckp.roster()->'ledgerOnly') @> '["s78sealed"]'::jsonb THEN
    RAISE EXCEPTION 's78 FAIL (e): a sealed kernel absent from the GUC is not reported in ledgerOnly. roster=%', ckp.roster();
  END IF;
  RAISE NOTICE 's78 (e) PASS — germination is existence, and the roster says so';

  -- (f) THE CONTROL: retired and non-canonical names must NOT enter ---------
  a := ckp._ledger_kernels();
  IF 's78retired' = ANY(a) THEN
    RAISE EXCEPTION 's78 FAIL (f): a RETIRED kernel entered the grant set';
  END IF;
  IF 'S78Caps' = ANY(a) OR 's78caps' = ANY(a) THEN
    RAISE EXCEPTION 's78 FAIL (f): a NON-CANONICAL kernel id entered the grant set — the door cannot route that name';
  END IF;
  RAISE NOTICE 's78 (f) PASS — retired and non-canonical names refused entry';

  -- (g) Q-2 digest stable; Q-3 plane honest about what it cannot classify ----
  d1 := ckp.dispatch('surface.refusals','{}'::jsonb)->>'registryDigest';
  d2 := ckp.dispatch('surface.refusals','{}'::jsonb)->>'registryDigest';
  IF d1 IS NULL OR length(d1) <> 64 OR d1 IS DISTINCT FROM d2 THEN
    RAISE EXCEPTION 's78 FAIL (g): registryDigest is not a stable sha256 (% vs %)', d1, d2;
  END IF;
  IF (SELECT count(*) FROM ckp.refusal_registry WHERE plane IS NULL) = 0 THEN
    RAISE EXCEPTION 's78 FAIL (g): every refusal got a plane — sqlstates 22023 and 42704 carry codes of BOTH planes, so a full classification is a guess, not a measurement';
  END IF;
  IF (SELECT count(*) FROM ckp.refusal_registry WHERE plane = 'declared') = 0 THEN
    RAISE EXCEPTION 's78 FAIL (g): nothing classified declared — the rule did not run';
  END IF;
  RAISE NOTICE 's78 (g) PASS — digest stable, plane NULL where classification would be a guess';

  -- (h) a module adopted twice composes once --------------------------------
  IF array_length(ckp._adopted_graphs('s78proj'),1) <> 1 THEN
    RAISE EXCEPTION 's78 FAIL (h): a module adopted twice appears % times', array_length(ckp._adopted_graphs('s78proj'),1);
  END IF;
  RAISE NOTICE 's78 (h) PASS — duplicate Adoption composes once';

  DELETE FROM ckp.instances WHERE id LIKE 's78-%' OR id LIKE 'urn:ckp:s78%' OR id LIKE 'urn:ckp:S78%';
  DELETE FROM ckp.kernel_epoch WHERE kernel IN ('s78virgin','s78adv');
EXCEPTION WHEN OTHERS THEN
  DELETE FROM ckp.instances WHERE id LIKE 's78-%' OR id LIKE 'urn:ckp:s78%' OR id LIKE 'urn:ckp:S78%';
  DELETE FROM ckp.kernel_epoch WHERE kernel IN ('s78virgin','s78adv');
  RAISE;
END $$;

\echo 's78 PASS — the outstanding list closed, each claim with its control'
