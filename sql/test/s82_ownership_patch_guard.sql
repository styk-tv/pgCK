-- s82_ownership_patch_guard.sql — THE TRIPLE A CLIENT CANNOT WRITE (0.4.102).
--
-- WHY THIS EXISTS. The germinate guard (0.4.89) decides who may re-germinate by
-- reading ckp:ownedBy; the apply gate (0.4.99) decides who may enact by reading
-- ckp:ownedBy. But ownedBy itself was an ordinary declared property, so ANY
-- party could rewrite it through instance.update and void both gates in one
-- step — measured on a virgin 0.4.101 (TDD E-4): a non-owner moved a Project
-- from tdd-e4-owner to tdd-e4-attacker with one call. Germination's own comment
-- calls ownedBy "the triple a client cannot write"; this file is what makes
-- that sentence a check instead of a hope.
--
-- The controls, and why each exists:
--   (a) CONTROL   a NON-OWNER's ownedBy patch is refused BY NAME
--                 (ownership_not_patchable) — not by a shape accident.
--   (b) CONTROL   the OWNER's ownedBy patch is ALSO refused. The rule is
--                 "server-derived, no transfer path", not "owner-gated" — an
--                 owner-initiated silent transfer would be an ungoverned
--                 hand-over with no receipt. The lawful transfer is a governed
--                 verb that does not exist yet; its absence is the filed
--                 finding.
--   (c) POSITIVE  an unrelated patch by the same non-owner still lands — the
--                 guard is a gate, not a wall.
--   (d) CONTROL   a NON-OWNER's projectKind patch is refused not_owner — the
--                 quorum floor (C-1/L-8) must not be movable by strangers.
--   (e) POSITIVE  the OWNER's projectKind patch lands — declaring the kind of
--                 one's own project is the owner's act.
--   (f) POSITIVE  (E-5) a patch addressed by the stamped @id form lands
--                 identically to the bare form — one id vocabulary, read and
--                 write alike.
--   (g) CONTROL   an unknown id still refuses unknown_instance and names the
--                 accepted forms — resolution must not blur existence.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  r jsonb; v_before text; v_after text;
BEGIN
  -- FIXTURE: a Project owned by s82-owner, kind shared. Direct INSERT is the
  -- artifact ritual: the fixture must exist BEFORE the door's rules are
  -- measured, and the door has no verb that writes somebody else's project.
  DELETE FROM ckp.instances WHERE id IN ('s82-proj','s82-plain');
  INSERT INTO ckp.instances(id, body) VALUES
    ('s82-proj', jsonb_build_object('@id','urn:ckp:project:s82','type',C||'Project',
       'http://www.w3.org/2000/01/rdf-schema#label','s82',
       C||'projectKind','shared', C||'ownedBy','urn:ckp:participant:s82-owner'));

  -- (a) non-owner ownedBy patch: refused BY NAME.
  PERFORM set_config('ckp.requester','s82-attacker',true);
  r := ckp.update_typed(jsonb_build_object('id','s82-proj',
        'patch', jsonb_build_object(C||'ownedBy','urn:ckp:participant:s82-attacker')));
  SELECT body->>(C||'ownedBy') INTO v_after FROM ckp.instances WHERE id='s82-proj';
  IF (r->>'ok')::boolean IS TRUE OR v_after <> 'urn:ckp:participant:s82-owner' THEN
    RAISE EXCEPTION 's82 (a) FAIL — a non-owner rewrote ownedBy: %', r;
  END IF;
  IF r->>'error' IS DISTINCT FROM 'ownership_not_patchable' THEN
    RAISE EXCEPTION 's82 (a) FAIL — refused, but NOT by the guard (got %). A control that accepts any failure proves nothing', r->>'error';
  END IF;
  RAISE NOTICE 's82 (a) PASS — non-owner ownedBy patch refused BY NAME (ownership_not_patchable)';

  -- (b) the OWNER is refused too: server-derived means server-derived.
  PERFORM set_config('ckp.requester','s82-owner',true);
  r := ckp.update_typed(jsonb_build_object('id','s82-proj',
        'patch', jsonb_build_object(C||'ownedBy','urn:ckp:participant:s82-friend')));
  IF r->>'error' IS DISTINCT FROM 'ownership_not_patchable' THEN
    RAISE EXCEPTION 's82 (b) FAIL — the OWNER patched ownedBy (got %): an ungoverned transfer path with no receipt', COALESCE(r->>'error','ok');
  END IF;
  RAISE NOTICE 's82 (b) PASS — the owner is refused too: no transfer verb exists, and a patch is not one';

  -- (c) the guard is a gate, not a wall: an unrelated patch still lands.
  PERFORM set_config('ckp.requester','s82-attacker',true);
  r := ckp.update_typed(jsonb_build_object('id','s82-proj',
        'patch', jsonb_build_object('http://www.w3.org/2000/01/rdf-schema#label','s82-relabelled')));
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's82 (c) FAIL — an unrelated patch was refused (%): the guard over-blocks', r->>'error';
  END IF;
  RAISE NOTICE 's82 (c) PASS — an unrelated patch by the same party lands: a gate, not a wall';

  -- (d) non-owner projectKind patch: refused not_owner.
  r := ckp.update_typed(jsonb_build_object('id','s82-proj',
        'patch', jsonb_build_object(C||'projectKind','personal')));
  SELECT body->>(C||'projectKind') INTO v_after FROM ckp.instances WHERE id='s82-proj';
  IF (r->>'ok')::boolean IS TRUE OR v_after <> 'shared' THEN
    RAISE EXCEPTION 's82 (d) FAIL — a stranger moved the quorum floor: %', r;
  END IF;
  IF r->>'error' IS DISTINCT FROM 'not_owner' THEN
    RAISE EXCEPTION 's82 (d) FAIL — refused, but NOT as not_owner (got %)', r->>'error';
  END IF;
  RAISE NOTICE 's82 (d) PASS — non-owner projectKind patch refused not_owner: the quorum floor is not a stranger''s to move';

  -- (e) the OWNER's projectKind patch lands.
  PERFORM set_config('ckp.requester','s82-owner',true);
  r := ckp.update_typed(jsonb_build_object('id','s82-proj',
        'patch', jsonb_build_object(C||'projectKind','personal')));
  SELECT body->>(C||'projectKind') INTO v_after FROM ckp.instances WHERE id='s82-proj';
  IF (r->>'ok')::boolean IS NOT TRUE OR v_after <> 'personal' THEN
    RAISE EXCEPTION 's82 (e) FAIL — the OWNER could not declare their own project''s kind: %', r;
  END IF;
  RAISE NOTICE 's82 (e) PASS — the owner''s projectKind patch lands: their project, their declaration';

  -- (f) E-5: the stamped @id form patches identically to the bare form.
  INSERT INTO ckp.instances(id, body) VALUES
    ('s82-plain', jsonb_build_object('@id','ckp://Thing#s82-plain','type','urn:ckp:s82/type/Thing',
       'urn:ckp:s82/type/note','bare'));
  r := ckp.update_typed(jsonb_build_object('id','ckp://Thing#s82-plain',
        'patch', jsonb_build_object('urn:ckp:s82/type/note','via-atid')));
  SELECT body->>'urn:ckp:s82/type/note' INTO v_after FROM ckp.instances WHERE id='s82-plain';
  IF (r->>'ok')::boolean IS NOT TRUE OR v_after <> 'via-atid' THEN
    RAISE EXCEPTION 's82 (f) FAIL — the @id form does not patch (%): read and write disagree about the id vocabulary', COALESCE(r->>'error','?');
  END IF;
  RAISE NOTICE 's82 (f) PASS — the stamped @id form patches identically to the bare form';

  -- (g) an unknown id still refuses, naming the accepted forms.
  r := ckp.update_typed(jsonb_build_object('id','ckp://Thing#s82-never-existed',
        'patch', jsonb_build_object('urn:ckp:s82/type/note','x')));
  IF r->>'error' IS DISTINCT FROM 'unknown_instance' OR r->>'hint' IS NULL THEN
    RAISE EXCEPTION 's82 (g) FAIL — unknown id must refuse unknown_instance WITH the accepted forms named: %', r;
  END IF;
  RAISE NOTICE 's82 (g) PASS — an unknown id refuses unknown_instance and names the accepted forms';

  DELETE FROM ckp.instances WHERE id IN ('s82-proj','s82-plain');
END $$;

-- (h) THE LIVE APPLY PATH. The 0.4.99 gate parsed the CALLER'S about for a
-- urn:ckp:<proj>/ prefix; a real apply addresses the Proposal @id
-- (ckp://Proposal#…), which that regex never matches — so the path every real
-- apply takes was ungated, and any party could enact a quorum-met proposal
-- against an owned project. The control runs the whole cycle: stranger
-- proposes and approves, stranger's apply BY THE PROPOSAL @id is refused
-- not_owner, the owner's identical apply lands. Re-applying the same add_class
-- re-emits the same named shape, so repeated smoke runs advance the epoch and
-- change no doctrine.
DO $$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  proj text := ckp._project(); r_p jsonb; r_v jsonb; r jsonb; r2 jsonb; pid text;
BEGIN
  DELETE FROM ckp.instances WHERE id='s82-sess-proj';
  INSERT INTO ckp.instances(id, body) VALUES
    ('s82-sess-proj', jsonb_build_object('@id','urn:ckp:project:'||proj,'type',C||'Project',
       'http://www.w3.org/2000/01/rdf-schema#label','s82-session',
       C||'ownedBy','urn:ckp:participant:s82-owner'));

  PERFORM set_config('ckp.requester','s82-stranger',true);
  r_p := ckp.propose_change(proj, jsonb_build_object('op','add_class',
           'detail', jsonb_build_object('class','urn:ckp:'||proj||'/type/S82Exercise')));
  IF (r_p->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's82 (h) FIXTURE FAIL — propose refused: %', r_p; END IF;
  pid := r_p->>'proposal';
  r_v := ckp.vote(jsonb_build_object('about', r_p->>'proposal_iri', 'value','approve'));
  IF (r_v->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's82 (h) FIXTURE FAIL — vote refused: %', r_v; END IF;

  r := ckp.apply(jsonb_build_object('about', r_p->>'proposal_iri'));
  IF r->>'error' IS DISTINCT FROM 'not_owner' THEN
    RAISE EXCEPTION 's82 (h) FAIL — a STRANGER applying by the proposal @id got % — the live path is ungated', COALESCE(r->>'error','ok');
  END IF;

  PERFORM set_config('ckp.requester','s82-owner',true);
  r2 := ckp.apply(jsonb_build_object('about', r_p->>'proposal_iri'));
  IF (r2->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's82 (h) FAIL — the OWNER''s identical apply did not land (%): a wall, not a gate', r2->>'error';
  END IF;
  RAISE NOTICE 's82 (h) PASS — live path: stranger refused not_owner by the proposal @id; the owner''s identical apply landed (epoch %)', r2->>'epoch';

  DELETE FROM ckp.instances WHERE id = 's82-sess-proj' OR id = pid
     OR (body->>'type' = C||'Vote' AND body->>(C||'about') = r_p->>'proposal_iri');
END $$;

\echo 's82 PASS — ownedBy unpatchable by anyone, projectKind owner-gated, one id vocabulary, the live apply path gated'
