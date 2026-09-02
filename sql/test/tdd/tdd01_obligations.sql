-- tdd01_obligations.sql — the 19 outstanding obligations, authored RED.
-- Run tdd00_harness.sql first. Every block records exactly one row and never
-- aborts: an unexpected error records BROKEN rather than killing the run, so one
-- bad probe cannot hide the other eighteen.
\set ON_ERROR_STOP 0

-- ═══ B-1 · scratch-graph reaper ════════════════════════════════════════════
DO $$
DECLARE n int; ids bigint[]; one bigint; g bigint; before int; after int;
BEGIN
  IF to_regprocedure('pgrdf.drop_graph(bigint,boolean)') IS NULL THEN
    PERFORM tdd('B-1','dead+empty scratch graphs the caller OWNS are reaped; non-empty and live are spared; an undroppable one is REPORTED, never silently skipped',
      'existence','RED','pgrdf.drop_graph() absent — engine predates it'); RETURN;
  END IF;
  -- BEHAVIOUR: make a dead-empty one, reap it, prove it is GONE; and prove a
  -- non-empty one SURVIVES the same pass (the control that stops an over-eager reaper).
  g := pgrdf.add_graph('urn:ckp:validate-scratch:999901');
  PERFORM pgrdf.parse_turtle('<urn:t1> <urn:t2> <urn:t3> .',
          pgrdf.add_graph('urn:ckp:validate-scratch:999902'), 'urn:t#');
  SELECT COALESCE(array_agg(x.graph_id),ARRAY[]::bigint[]) INTO ids FROM (
    SELECT gg.graph_id FROM pgrdf._pgrdf_graphs gg
     WHERE gg.iri IN ('urn:ckp:validate-scratch:999901','urn:ckp:validate-scratch:999902')
       AND NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = gg.graph_id)) x;
  FOREACH one IN ARRAY ids LOOP PERFORM pgrdf.drop_graph(one,true); END LOOP;
  SELECT count(*) INTO after FROM pgrdf._pgrdf_graphs WHERE iri='urn:ckp:validate-scratch:999901';
  SELECT count(*) INTO before FROM pgrdf._pgrdf_graphs WHERE iri='urn:ckp:validate-scratch:999902';
  BEGIN PERFORM pgrdf.drop_graph((SELECT graph_id FROM pgrdf._pgrdf_graphs WHERE iri='urn:ckp:validate-scratch:999902'),true); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF after = 0 AND before = 1 THEN
    PERFORM tdd('B-1','dead+empty scratch graphs the caller OWNS are reaped; non-empty and live are spared; an undroppable one is REPORTED, never silently skipped',
      'behaviour','GREEN','dead+empty GONE, non-empty SURVIVED. NOTE: measured on this door, pgrdf partitions are 134 ck_substrate / 21 pgck and pgrdf.drop_graph is NOT security-definer, so the reap drops only what its effective role owns — an unowned one raises a WARNING rather than failing silently, which is why the per-graph handler logs');
  ELSE
    PERFORM tdd('B-1','dead+empty scratch graphs the caller OWNS are reaped; non-empty and live are spared; an undroppable one is REPORTED, never silently skipped',
      'behaviour','RED', format('empty survived(%s) or non-empty was taken(%s)', after, before));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('B-1','dead+empty scratch graphs the caller OWNS are reaped; non-empty and live are spared; an undroppable one is REPORTED, never silently skipped',
    'behaviour','BROKEN', 'probe errored: '||SQLERRM);
END $$;

-- ═══ C-1 · L-8 quorum derived from projectKind ════════════════════════════
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        f_shared int; f_personal int; f_absent int;
        r1 jsonb; r2 jsonb; e2e text := 'untested';   -- OUTER scope: the first
        -- draft declared these in a nested block and referenced them in the IF
        -- chain below, which is out of scope. The harness reported BROKEN, not
        -- RED, which is exactly the distinction it exists to make.
BEGIN
  IF to_regprocedure('ckp._quorum_floor(text)') IS NULL THEN
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'existence','RED','nothing reads projectKind when computing quorum — it resolves to COALESCE(...,1) at both call sites, so a project can declare it needs a partner and then approve its own change alone'); RETURN;
  END IF;

  -- FIXTURES, so the verdict does not depend on which projects happen to exist.
  INSERT INTO ckp.instances(id, body) VALUES
    ('tdd-c1-shared',   jsonb_build_object('@id','urn:ckp:project:tddc1shared','type',C||'Project', C||'projectKind','shared')),
    ('tdd-c1-personal', jsonb_build_object('@id','urn:ckp:project:tddc1personal','type',C||'Project', C||'projectKind','personal')),
    ('tdd-c1-absent',   jsonb_build_object('@id','urn:ckp:project:tddc1absent','type',C||'Project'))
  ON CONFLICT (id) DO NOTHING;

  f_shared   := ckp._quorum_floor('tddc1shared');
  f_personal := ckp._quorum_floor('tddc1personal');
  f_absent   := ckp._quorum_floor('tddc1absent');

  -- END-TO-END, because the claim's verb is REFUSES and a floor function is only
  -- the mechanism. Testing the mechanism and reporting the claim is the gap this
  -- suite keeps catching in its own probes.
  BEGIN
    PERFORM set_config('ckp.requester','svc:tdd-c1',true);
    INSERT INTO ckp.instances(id, body) VALUES
      ('tdd-c1-live', jsonb_build_object('@id','urn:ckp:project:'||ckp._project(),
                                         'type',C||'Project', C||'projectKind','shared'))
      ON CONFLICT (id) DO NOTHING;
    r1 := ckp.propose_change(ckp._project(), jsonb_build_object('op','add_class','requires_quorum',1,
            'detail', jsonb_build_object('class','urn:ckp:'||ckp._project()||'/type/TddC1','label','TddC1')));
    r2 := ckp.propose_change(ckp._project(), jsonb_build_object('op','add_class','requires_quorum',2,
            'detail', jsonb_build_object('class','urn:ckp:'||ckp._project()||'/type/TddC1b','label','TddC1b')));
    DELETE FROM ckp.instances WHERE id = 'tdd-c1-live';
    IF (r1->>'ok')::boolean IS TRUE THEN e2e := 'quorum-1-accepted';
    ELSIF (r2->>'ok')::boolean IS NOT TRUE THEN e2e := 'quorum-2-also-refused';
    ELSE e2e := 'ok'; END IF;
  EXCEPTION WHEN OTHERS THEN
    BEGIN DELETE FROM ckp.instances WHERE id='tdd-c1-live'; EXCEPTION WHEN OTHERS THEN NULL; END;
    e2e := 'probe-error';
  END;

  DELETE FROM ckp.instances WHERE id LIKE 'tdd-c1-%';

  IF e2e = 'quorum-1-accepted' THEN
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','RED','the floor computes correctly but propose_change still ACCEPTED quorum 1 on a shared project — the mechanism exists and the claim does not hold');
  ELSIF e2e = 'quorum-2-also-refused' THEN
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','RED','quorum 2 was refused too — a wall, not a gate');
  ELSIF f_shared < 2 THEN
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','RED', format('a `shared` project has floor %s — it can still approve its own change alone, which is exactly what shared is declared to prevent', f_shared));
  ELSIF f_personal <> 1 THEN
    -- CONTROL: personal is quorum-of-one BY DECLARATION. A floor that refuses it
    -- too is a wall, not a gate, and would break every legitimate solo project.
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','RED', format('a `personal` project has floor %s — quorum-of-one is its declared meaning; refusing it makes this a wall', f_personal));
  ELSIF f_absent <> 1 THEN
    -- CONTROL: an undeclared kind must impose NOTHING. Inventing a floor for a
    -- project that never declared a mating type is the substrate choosing a
    -- reproductive strategy nobody asked for — the defect 0.4.81 fixed by making
    -- the default NULL rather than 'personal'.
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','RED', format('a project with NO declared kind got floor %s — a rule invented for a declaration nobody made', f_absent));
  ELSE
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it; an undeclared kind imposes NO floor',
      'behaviour','GREEN','shared floor=2, personal floor=1, undeclared floor=1; and end-to-end propose REFUSED quorum 1 on a shared project while accepting quorum 2 — the locus is read, it binds only what declared itself, and it is a gate not a wall');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.instances WHERE id LIKE 'tdd-c1-%'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-2 · ownership enforced on apply, in the substrate ══════════════════
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#'; d text;
        proj text; r_stranger jsonb; r_owner jsonb; r_undeclared jsonb; pid text;
        r_p jsonb; r_v jsonb; r_es jsonb; r_eo jsonb;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='ckp' AND p.proname='apply' LIMIT 1;
  IF d IS NULL OR d NOT LIKE '%not_owner%' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED','ckp.apply checks proposal exists + pending + distinct approvals only. NO ownership check — the owner-applies rule lives in a client, and a screen is not a gate'); RETURN;
  END IF;

  proj := ckp._project();
  -- FIXTURE: a Project owned by somebody who is definitely not us.
  INSERT INTO ckp.instances(id, body) VALUES
    ('tdd-c2-proj', jsonb_build_object('@id','urn:ckp:project:'||proj,'type',C||'Project',
                                       C||'ownedBy','urn:ckp:participant:tdd-c2-someone-else'))
    ON CONFLICT (id) DO NOTHING;
  PERFORM set_config('ckp.requester','tdd-c2-not-the-owner',true);
  r_stranger := ckp.apply(jsonb_build_object('about','urn:ckp:'||proj||'/kernel/ck'));
  -- CONTROL 1: the OWNER must NOT be refused for ownership. (It will fail for
  -- another reason — unknown_proposal — and that is the point: the ownership gate
  -- must not be what stops them.)
  PERFORM set_config('ckp.requester','tdd-c2-someone-else',true);
  r_owner := ckp.apply(jsonb_build_object('about','urn:ckp:'||proj||'/kernel/ck'));
  -- END-TO-END (0.4.102, the second half). The gate above hears
  -- about=urn:ckp:<proj>/… — but a LIVE apply addresses the Proposal @id
  -- (ckp://Proposal#…), a spelling the 0.4.99 regex never matches, so the path
  -- real applies take was ungated and this probe was GREEN against an input
  -- class the live verb never carries. Run the whole cycle while the fixture
  -- owner stands: propose (floor 1 — the fixture declares no kind), approve,
  -- apply as the STRANGER by the proposal's @id — must refuse not_owner — then
  -- as the OWNER — must land. The landed apply is also the ledger's first REAL
  -- epoch advance, which is exactly the moment E-1 below needs to measure.
  PERFORM set_config('ckp.requester','tdd-c2-not-the-owner',true);
  r_p := ckp.propose_change(proj, jsonb_build_object('op','add_class',
           'detail', jsonb_build_object('class','urn:ckp:'||proj||'/type/TddC2Exercise')));
  IF (r_p->>'ok')::boolean IS TRUE THEN
    r_v  := ckp.vote(jsonb_build_object('about', r_p->>'proposal_iri', 'value','approve'));
    r_es := ckp.apply(jsonb_build_object('about', r_p->>'proposal_iri'));
    PERFORM set_config('ckp.requester','tdd-c2-someone-else',true);
    r_eo := ckp.apply(jsonb_build_object('about', r_p->>'proposal_iri'));
  END IF;
  -- CONTROL 2: an UNDECLARED owner imposes nothing.
  DELETE FROM ckp.instances WHERE id='tdd-c2-proj';
  PERFORM set_config('ckp.requester','tdd-c2-anyone',true);
  r_undeclared := ckp.apply(jsonb_build_object('about','urn:ckp:'||proj||'/kernel/ck'));

  IF r_stranger->>'error' IS DISTINCT FROM 'not_owner' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED', 'a STRANGER was not refused for ownership — got '||COALESCE(r_stranger->>'error','ok'));
  ELSIF r_owner->>'error' = 'not_owner' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED','the OWNER was refused for ownership — a wall, not a gate');
  ELSIF r_undeclared->>'error' = 'not_owner' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED','a project with NO declared owner still refused — an owner invented for a declaration nobody made');
  ELSIF (r_p->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','BROKEN','e2e propose failed: '||COALESCE(r_p->>'error','?'));
  ELSIF (r_v->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','BROKEN','e2e vote failed: '||COALESCE(r_v->>'error','?'));
  ELSIF r_es->>'error' IS DISTINCT FROM 'not_owner' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED','the LIVE path is ungated: a stranger applying the proposal BY ITS @id got '||COALESCE(r_es->>'error','ok')||' — the 0.4.99 gate hears a spelling real applies never carry');
  ELSIF (r_eo->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','RED','the OWNER''s live apply did not land — got '||COALESCE(r_eo->>'error','?')||' — a wall, not a gate');
  ELSE
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not; an unowned project imposes NOTHING',
      'behaviour','GREEN','stranger refused not_owner on BOTH spellings (direct urn and the live proposal path); the owner''s live apply landed; undeclared owner imposes nothing');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.instances WHERE id='tdd-c2-proj'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-3 · a registered obligation actually REFUSES ═══════════════════════
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        proj text := ckp._project(); real_iri text;
        bad_msg text := ''; good_ok bool := false; other_ok bool := false; other_msg text := '';
BEGIN
  PERFORM set_config('ckp.requester','svc:tdd-c3',true);
  SELECT g.iri INTO real_iri FROM pgrdf._pgrdf_graphs g
   WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id=g.graph_id AND NOT q.is_inferred)
   ORDER BY g.graph_id LIMIT 1;
  IF real_iri IS NULL THEN
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','BROKEN','no non-empty graph to point a conforming Adoption at — fixture problem'); RETURN;
  END IF;

  -- REGISTER. The claim is about the gate REFUSING, not about how it was
  -- registered; the governed route (add_proof_obligation) is a separate act.
  INSERT INTO ckp.proof_obligations(project, obligation, target_type, check_name, active)
  VALUES (proj, 'tdd-c3-adopts', C||'Adoption', 'adopts-resolves', true)
  ON CONFLICT (project, obligation) DO UPDATE SET active = true;

  -- (a) VIOLATING: adopts a module IRI with nothing behind it.
  BEGIN
    PERFORM ckp.seal('tdd-c3-bad', jsonb_build_object(
      '@id','ckp://Adoption#tdd-c3-bad','type',C||'Adoption',
      C||'adopts','urn:ckp:module:tdd-c3-nothing-here',
      -- AdoptionShape's required trio, so the SHAPE cannot be what refuses and
      -- the obligation is the only thing left that can. The first draft omitted
      -- them and the probe correctly reported "refused, but NOT by the
      -- obligation" — a control that accepts any failure proves nothing.
      C||'intoEpoch', to_jsonb(0),
      C||'sourceDigest', repeat('a',64),
      C||'intoProject','urn:ckp:'||proj));
  EXCEPTION WHEN OTHERS THEN bad_msg := SQLERRM;
  END;

  -- (b) CONFORMING: same type, adopts a graph that really resolves.
  BEGIN
    PERFORM ckp.seal('tdd-c3-good', jsonb_build_object(
      '@id','ckp://Adoption#tdd-c3-good','type',C||'Adoption',
      C||'adopts', real_iri,
      C||'intoEpoch', to_jsonb(0),
      C||'sourceDigest', repeat('b',64),
      C||'intoProject','urn:ckp:'||proj));
    good_ok := true;
  EXCEPTION WHEN OTHERS THEN good_ok := false;
  END;

  -- (c) UNRELATED TYPE: the obligation targets Adoption; a Vote must be untouched.
  BEGIN
    PERFORM ckp.seal('tdd-c3-other', jsonb_build_object(
      '@id','ckp://Vote#tdd-c3-other','type',C||'Vote'));
    other_ok := true;
  EXCEPTION WHEN OTHERS THEN other_ok := false; other_msg := SQLERRM;
  END;

  DELETE FROM ckp.proof_obligations WHERE project = proj AND obligation = 'tdd-c3-adopts';
  DELETE FROM ckp.instances WHERE id IN ('tdd-c3-bad','tdd-c3-good','tdd-c3-other');

  IF bad_msg = '' THEN
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','RED','a violating Adoption SEALED — the obligation is registered and refuses nothing');
  ELSIF position('adopts-resolves' in bad_msg) = 0 THEN
    -- the wrong-reason trap, made explicit: a shape refusal is not an obligation
    -- refusal, and a control that accepts any failure proves nothing.
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','RED','refused, but NOT by the obligation — got: '||left(bad_msg,120));
  ELSIF NOT good_ok THEN
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','RED','a CONFORMING Adoption was also refused — a wall, not a gate');
  ELSIF NOT other_ok AND position('adopts-resolves' in other_msg) > 0 THEN
    -- The control's claim is that the obligation does NOT FIRE on another type.
    -- A bare Vote also fails VoteShape, and that refusal is irrelevant here —
    -- asserting merely "it was refused" would fail the control for the wrong
    -- reason, which is the same trap this file catches everywhere else.
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','RED','the obligation fired on an UNRELATED type — it is not scoped to its target_type: '||left(other_msg,100));
  ELSE
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; a conforming seal and an unrelated type still land',
      'behaviour','GREEN','violating Adoption refused BY the obligation ('||left(bad_msg,60)||'…); conforming Adoption sealed; the obligation did NOT fire on an unrelated type');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    DELETE FROM ckp.proof_obligations WHERE obligation='tdd-c3-adopts';
    DELETE FROM ckp.instances WHERE id IN ('tdd-c3-bad','tdd-c3-good','tdd-c3-other');
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-4 · set_kernel_policy projector ═════════════════════════════════════
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        comp int; base text; kid text; r jsonb; in_ok bool; bad int := 0;
BEGIN
  IF NOT EXISTS (WITH f AS MATERIALIZED (
                   SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='ckp' AND p.prokind='f')
                 SELECT 1 FROM f WHERE pg_get_functiondef(f.oid) LIKE '%set_kernel_policy%') THEN
    PERFORM tdd('C-4','set_kernel_policy writes a Kernel property through propose->vote->apply; an out-of-range value AND a misspelled field are both refused',
      'existence','RED','the op is not in the allowed set — the seven policy fields the law declares are unreachable by the route the law mandates');
    RETURN;
  END IF;

  comp := ckp._composed_shapes(ckp._project());
  base := '@prefix ckp: <'||C||'> . @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
           @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:tddc4/kernel> a ckp:Kernel ; rdfs:label "t" ; ckp:epoch 0 ;
      ckp:inProject <urn:ckp:project:tddc4> ; ckp:transportSegment "tddc4" ;
      ckp:hasOrgan <urn:ckp:tddc4/organ/ck>, <urn:ckp:tddc4/organ/tool>, <urn:ckp:tddc4/organ/data> ';
  in_ok := ckp.validate(base||'; ckp:weightAssent "1.0"^^xsd:decimal ; ckp:weightDissent "-0.8"^^xsd:decimal .', comp);
  IF ckp.validate(base||'; ckp:weightDissent "0.5"^^xsd:decimal .', comp)  THEN bad := bad+1; END IF;
  IF ckp.validate(base||'; ckp:weightImplicit "1.5"^^xsd:decimal .', comp) THEN bad := bad+1; END IF;
  IF ckp.validate(base||'; ckp:decayLambda "-0.1"^^xsd:decimal .', comp)   THEN bad := bad+1; END IF;
  IF ckp.validate(base||'; ckp:thresholdPromote "0.5"^^xsd:decimal ; ckp:thresholdDiscard "0.9"^^xsd:decimal .', comp) THEN bad := bad+1; END IF;

  -- the half that is NOT satisfied: a MISSPELLED field must be refused too. An
  -- out-of-range value is caught by the shape; a field that does not exist is
  -- targeted by no shape and conforms VACUOUSLY, which is worse.
  PERFORM set_config('ckp.requester','svc:tdd-c4',true);
  SELECT body->>'@id' INTO kid FROM ckp.instances WHERE body->>'type'=C||'Kernel' ORDER BY ts_created LIMIT 1;
  r := ckp.update_typed(jsonb_build_object('id',kid,'patch',jsonb_build_object(C||'weightTddC4Nonsense',0.5)));

  IF NOT in_ok THEN
    PERFORM tdd('C-4','set_kernel_policy writes a Kernel property through propose->vote->apply; an out-of-range value AND a misspelled field are both refused',
      'behaviour','BROKEN','an in-range policy set does not conform — the premise is wrong, so every control below passes for the wrong reason');
  ELSIF bad > 0 THEN
    PERFORM tdd('C-4','set_kernel_policy writes a Kernel property through propose->vote->apply; an out-of-range value AND a misspelled field are both refused',
      'behaviour','RED', bad||' of 4 out-of-range control(s) CONFORMED — the law is not enforcing its own bounds, so the projector would have to carry a copy after all');
  ELSIF (r->>'ok')::boolean IS TRUE THEN
    PERFORM tdd('C-4','set_kernel_policy writes a Kernel property through propose->vote->apply; an out-of-range value AND a misspelled field are both refused',
      'behaviour','RED','bounds hold, but a MISSPELLED field in full-IRI form was ACCEPTED onto a sealed Kernel — see E-3. Out-of-range is refused; nonexistent is minted and conforms vacuously');
  ELSE
    PERFORM tdd('C-4','set_kernel_policy writes a Kernel property through propose->vote->apply; an out-of-range value AND a misspelled field are both refused',
      'behaviour','GREEN','four out-of-range controls refused (incl. the cross-property invariant) and a misspelled field refused by name');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-4','set_kernel_policy writes a Kernel property','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-5 · participation scope (cross-kernel rule layer) ═══════════════════
DO $$
BEGIN
  PERFORM tdd('C-5','a rule can be scoped to a NAMED SET of kernels; it binds them and does not bind others',
    'existence','RED','no scope between core (everyone) and one kernel. proof_obligations PK is (project,obligation); adoption is per project; core is global. The middle has no home');
END $$;

-- ═══ C-6 · Tier-2 in-kernel roles ══════════════════════════════════════════
DO $$
BEGIN
  PERFORM tdd('C-6','an in-kernel role NARROWS what a participant may do inside one kernel and can never widen the Tier-1 floor',
    'existence','RED','ckp.grants has 0 rows and is (grantee,permission) — 3 declared dimensions flattened to 1. No role is read anywhere');
END $$;

-- ═══ C-7 · onBehalfOf stamped ══════════════════════════════════════════════
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ckp.instances WHERE body ? 'https://conceptkernel.org/ontology/v3.11/core#onBehalfOf';
  IF n = 0 THEN
    PERFORM tdd('C-7','an agent seal carries onBehalfOf; a direct human seal does NOT (absence is the signal)',
      'existence','RED','declared in core with rdfs:subPropertyOf prov:actedOnBehalfOf, and written by NOTHING — 0 instances carry it');
  ELSE
    PERFORM tdd('C-7','an agent seal carries onBehalfOf; a direct human seal does NOT (absence is the signal)',
      'existence','RED', n||' instances carry it — now prove the ABSENCE case too, or the stamp means nothing');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-7','an agent seal carries onBehalfOf; a direct human seal does NOT (absence is the signal)','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-8 · Signal + dwellMillis ════════════════════════════════════════════
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ckp.instances WHERE body->>'type' LIKE '%#Signal';
  PERFORM tdd('C-8','an implicit Signal seals with dwellMillis as ONE hash-chained boundary head, never per event; never-saw seals nothing',
    'existence','RED', CASE WHEN n=0 THEN 'ckp:Signal and ckp:dwellMillis are declared; 0 Signal instances exist and no verb seals one'
                            ELSE n||' Signals exist — now prove the boundary head, and that never-saw is free' END);
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-8','an implicit Signal seals with dwellMillis as ONE hash-chained boundary head','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-9 · Score computed on the tick, bounded to DRAFT ════════════════════
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ckp.instances WHERE body->>'type' LIKE '%#Score';
  PERFORM tdd('C-9','a Score crossing thresholdPromote DRAFTS a Proposal and the tick seals/votes/applies NOTHING',
    'existence','RED', CASE WHEN n=0 THEN 'ckp:Score declared with computedAtEpoch; 0 exist. The score/tick engine row is empty'
                            ELSE n||' Scores exist — now prove the tick DRAFTED and did not seal, vote or apply' END);
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-9','a Score crossing thresholdPromote DRAFTS a Proposal and the tick seals nothing','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-10 · orbits ═════════════════════════════════════════════════════════
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pgrdf._pgrdf_dictionary WHERE lexical_value LIKE '%core#Orbit%' OR lexical_value LIKE '%core#period%';
  PERFORM tdd('C-10','a kernel declares period/lead/seat as LAW; the next crossing is computable by a third party without asking the kernel',
    'existence','RED', CASE WHEN n=0 THEN 'no ckp:Orbit, no period, no phase in the loaded law — CK-dev states it outright: "the substrate declares no cadence for anything"'
                            ELSE 'orbit terms appearing ('||n||') — now prove third-party computability and that the clock is NOT windable' END);
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-10','a kernel declares period/lead/seat as LAW','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-11 · orbit work queue ═══════════════════════════════════════════════
DO $$
BEGIN
  IF to_regclass('ckp.orbit_job') IS NULL THEN
    PERFORM tdd('C-11','a crossing ENQUEUES and never executes; the drain is bounded, counts attempts, and is fair across kernels',
      'existence','RED','no orbit queue exists. The pattern is already proven twice — outbox (<=100/tick, attempt_count) and materialize_job (1/tick, SKIP LOCKED, attempt_count + last_error)');
  ELSE
    PERFORM tdd('C-11','a crossing ENQUEUES and never executes; the drain is bounded, counts attempts, and is fair across kernels',
      'existence','RED','queue exists — now prove: crossing does not execute, drain is bounded, a failing job does NOT starve others');
  END IF;
END $$;

-- ═══ C-12 · per-kernel resource accounting ═════════════════════════════════
DO $$
DECLARE s jsonb; g bigint;
BEGIN
  IF to_regprocedure('ckp.storage()') IS NULL THEN
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one','existence','RED','ckp.storage() absent'); RETURN;
  END IF;
  s := ckp.storage();
  IF NOT (s ? 'perKernel') THEN
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
      'existence','RED','ckp.storage() reports the WHOLE database. Graphs are prefixed by kernel so the data is already attributable — the gap is a report, not a mechanism'); RETURN;
  END IF;
  -- FIXTURE: a graph under a kernel prefix nobody else uses, so attribution is
  -- proven against a KNOWN row and not read off ambient data (the C-13 lesson).
  g := pgrdf.add_graph('urn:ckp:tddc12/probe');
  s := ckp.storage();
  PERFORM pgrdf.drop_graph(g, false);
  IF COALESCE((s->'perKernel'->'tddc12'->>'graphs')::int, 0) < 1 THEN
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
      'behaviour','RED','perKernel present but a graph created under urn:ckp:tddc12/ was NOT attributed to tddc12 — the report exists and the attribution is wrong');
  ELSIF s->'perKernel'->'substrate' IS NULL
        OR (s->'perKernel' ? substring('urn:ckp:core' from '^urn:ckp:([a-z0-9-]+)$')) THEN
    -- the trap this control exists for: shared weight (core, modules, scratch)
    -- silently landing in somebody's column manufactures busy-vs-bad confusion.
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
      'behaviour','RED','no substrate bucket — shared graphs (core, modules, scratch) are being attributed to kernels or dropped');
  ELSE
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
      'behaviour','GREEN','a fixture graph under urn:ckp:tddc12/ was attributed to tddc12 ('||
        (s->'perKernel'->'tddc12')::text||'); shared graphs land in the named substrate bucket');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-12','storage is reported PER KERNEL','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-13 · ckp:epoch on the sealed Kernel ═════════════════════════════════
-- The claim: a sealed instance carries no value a reader can mistake for a
-- live one — either it tracks, or its NAME says it does not. The defect was
-- the LAW itself: KernelShape demanded ckp:epoch minCount 1, so germination
-- HAD to stamp a counter that went stale on the first apply, and every board
-- drew it as live (every sun rendered e0). The cure (0.4.104) renames the
-- germination moment to germinatedAtEpoch — immutable by meaning, honest by
-- name — and the emitter follows the LOADED law, because stamping against the
-- other law is a MinCount refusal (the 0.4.88 G-1 class). Kernels sealed
-- before the rename still carry the old stamp: fenced history, reported and
-- never judged, exactly like the anon-applied proposals.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        law_forces int; declared int; r jsonb; body jsonb; legacy int;
BEGIN
  -- law control, measured off the LOADED core graph, not the tracked file
  SELECT count(*) INTO law_forces FROM pgrdf.sparql(
    'PREFIX sh: <http://www.w3.org/ns/shacl#>
     PREFIX ckp: <'||C||'>
     SELECT ?b WHERE { GRAPH <urn:ckp:core> {
       ckp:KernelShape sh:property ?b . ?b sh:path ckp:epoch } }');
  SELECT count(*) INTO declared FROM pgrdf.sparql(
    'PREFIX ckp: <'||C||'>
     SELECT ?o WHERE { GRAPH <urn:ckp:core> { ckp:germinatedAtEpoch ?p ?o } }');

  IF law_forces > 0 THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','RED','the LOADED KernelShape still carries a ckp:epoch path — the law forces the stamp, and the emitter rightly follows the loaded law'); RETURN;
  END IF;
  IF declared = 0 THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','RED','the law dropped the stamp but germinatedAtEpoch is undeclared — the name that says it does not track is missing'); RETURN;
  END IF;

  -- FIXTURE: a REAL germination, through the governed emitter — the only
  -- honest way to measure what germination stamps. Re-runs re-germinate the
  -- same owner's kernel, which the guard permits.
  PERFORM set_config('ckp.requester','svc:tdd-c13',true);
  r := ckp.germinate_kernel('tddc13','tdd-c13','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','BROKEN','fixture germination refused: '||COALESCE(r->>'error','?')); RETURN;
  END IF;
  SELECT i.body INTO body FROM ckp.instances i
   WHERE i.body->>'@id' = 'urn:ckp:tddc13/kernel'
     AND i.body->>'type' = C||'Kernel'
   ORDER BY i.ts_created DESC LIMIT 1;
  SELECT count(*) INTO legacy FROM ckp.instances i
   WHERE i.body->>'type' = C||'Kernel' AND i.body ? (C||'epoch')
     AND i.body->>'@id' IS DISTINCT FROM 'urn:ckp:tddc13/kernel';

  IF body ? (C||'epoch') THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','RED','the law no longer forces it and germination STILL stamps mutable ckp:epoch on the sealed Kernel');
  ELSIF NOT (body ? (C||'germinatedAtEpoch')) THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','RED','neither stamp — the germination moment is unrecorded, which trades a misleading value for a missing fact');
  ELSE
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','GREEN','germination stamps germinatedAtEpoch (immutable by name); the loaded law no longer forces ckp:epoch; '||legacy||' pre-rename Kernel(s) carry the retired stamp as fenced history');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-14 · routed vs declared affordances ═════════════════════════════════
-- Both halves or neither (pgCK#56). Measured PER GERMINATED KERNEL — a kernel
-- with no kernel graph is a seed routing row, not a real kernel, and declaring
-- its capability would be premature (and would steal the bootstrap graph id).
-- The probe germinates its own fixture kernel with a routed verb, then proves
-- the backfill converges: every routed verb of a germinated kernel is
-- declared with a derivedBy that RESOLVES, and a second run seals nothing.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#';
        r jsonb; missing int; unresolved int;
BEGIN
  IF to_regprocedure('ckp.declare_routed_affordances()') IS NULL THEN
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','RED','no backfill verb exists — capability cannot be derived honestly from a registry the ledger does not back'); RETURN;
  END IF;

  PERFORM set_config('ckp.requester','svc:tdd-c14',true);
  DELETE FROM ckp.affordance_registry WHERE kernel='tddc14';
  r := ckp.germinate_kernel('tddc14','tdd-c14','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','BROKEN','fixture germination refused: '||COALESCE(r->>'error','?')); RETURN;
  END IF;
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, out_topic, plane, delegate)
  VALUES ('tddc14','tddc14.probe','input.kernel.tddc14.action.tddc14.probe','result.kernel.tddc14.tddc14.probe','query',false);

  r := ckp.declare_routed_affordances();

  -- every routed verb of a GERMINATED kernel is now declared PAIRWISE...
  SELECT count(*) INTO missing FROM ckp.affordance_registry ar
   WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_graphs g WHERE g.iri = format('urn:ckp:%s/kernel/ck', ar.kernel))
     AND NOT EXISTS (SELECT 1 FROM ckp.instances i
                      WHERE i.body->>'@id' = 'ckp://Affordance#'||ar.kernel||'.'||ar.verb
                        AND i.body->>'type' = C||'Affordance');
  -- ...and every sealed Affordance's derivedBy RESOLVES to a Materialization
  -- (the F-P2-5 phantom-reference control: a declaration citing an act that
  -- does not exist is worse than an absent one).
  SELECT count(*) INTO unresolved FROM ckp.instances a
   WHERE a.body->>'type' = C||'Affordance'
     AND NOT EXISTS (SELECT 1 FROM ckp.instances m
                      WHERE m.body->>'@id' = a.body->>(C||'derivedBy') AND m.body->>'type' = C||'Materialization');

  DELETE FROM ckp.affordance_registry WHERE kernel='tddc14';
  DELETE FROM ckp.instances WHERE id IN ('aff-tddc14-tddc14-probe','mat-tddc14-aff-backfill-0','epoch-tddc14-0');
  -- and the epoch ROW: deleting the sealed Epoch while leaving the row's
  -- digest manufactures E-1's "value invented for a moment nobody measured" —
  -- this file's own D-1 lesson, relearned here the same way.
  DELETE FROM ckp.kernel_epoch WHERE kernel='tddc14';

  IF missing > 0 THEN
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','RED','the backfill ran and '||missing||' routed verb(s) of germinated kernels are STILL undeclared; failures: '||COALESCE((r->'failed')::text,'?'));
  ELSIF unresolved > 0 THEN
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','RED', unresolved||' sealed Affordance(s) cite a derivedBy that resolves to no Materialization — a phantom declaration, worse than an absent one');
  ELSE
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','GREEN','every germinated kernel''s routes declared PAIRWISE, each derivedBy resolves; this run backfilled '||COALESCE(r->>'sealed','0')||' and is idempotent');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.affordance_registry WHERE kernel='tddc14'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-15 · every refusal-shaped prose is typed ════════════════════════════
-- The first draft counted FUNCTIONS lacking 'sqlstate' anywhere — a function
-- with ten refusals and one typed passed. The honest unit is the SITE: every
-- jsonb_build_object('ok', false …) either carries 'sqlstate' within its own
-- construction, or it is a fault the exception block stamps with the REAL
-- SQLSTATE. And the code must be REGISTERED — a sqlstate nobody can look up
-- teaches nothing.
DO $$
DECLARE untyped int; unregistered int; ex text; r jsonb; reg text;
BEGIN
  WITH f AS MATERIALIZED (
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='ckp' AND p.prokind='f'),
  sites AS (
    SELECT f.proname, s.chunk FROM f,
           LATERAL regexp_split_to_table(pg_get_functiondef(f.oid),
                   'jsonb_build_object\(''ok'', false') WITH ORDINALITY AS s(chunk, ord)
     WHERE s.ord > 1)
  SELECT count(*) FILTER (WHERE left(chunk,300) NOT LIKE '%sqlstate%'),
         string_agg(DISTINCT proname, ', ') FILTER (WHERE left(chunk,300) NOT LIKE '%sqlstate%')
    INTO untyped, ex FROM sites;

  WITH f AS MATERIALIZED (
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='ckp' AND p.prokind='f'),
  codes AS (
    SELECT DISTINCT m[1] AS code FROM f,
           LATERAL regexp_matches(pg_get_functiondef(f.oid), '''error'', ''([a-z0-9_]+)''', 'g') m)
  SELECT count(*), string_agg(code, ', ') INTO unregistered, reg
    FROM codes WHERE NOT EXISTS (SELECT 1 FROM ckp.refusal_registry rr WHERE rr.code = codes.code);

  IF untyped > 0 THEN
    PERFORM tdd('C-15','every refusal carries a registered code and sqlstate; an ok:false with neither is fault-shaped',
      'behaviour','RED', untyped||' refusal site(s) carry no sqlstate in their own construction (in: '||COALESCE(ex,'?')||')');
  ELSIF unregistered > 0 THEN
    PERFORM tdd('C-15','every refusal carries a registered code and sqlstate; an ok:false with neither is fault-shaped',
      'behaviour','RED', unregistered||' returned error code(s) are NOT in ckp.refusal_registry: '||COALESCE(reg,'?')||' — a code nobody can look up teaches nothing');
  ELSE
    -- CONTROL: a LIVE refusal's sqlstate must equal the registered one, or the
    -- registry documents something the wire does not say.
    r := ckp.update_typed(jsonb_build_object('id','tdd-c15-never-existed','patch',jsonb_build_object('x',1)));
    IF r->>'error' IS DISTINCT FROM 'unknown_instance'
       OR r->>'sqlstate' IS DISTINCT FROM (SELECT rr.sqlstate FROM ckp.refusal_registry rr WHERE rr.code='unknown_instance') THEN
      PERFORM tdd('C-15','every refusal carries a registered code and sqlstate; an ok:false with neither is fault-shaped',
        'behaviour','RED','a live unknown_instance refusal does not match its registered sqlstate — got '||COALESCE(r->>'sqlstate','none'));
    ELSE
      PERFORM tdd('C-15','every refusal carries a registered code and sqlstate; an ok:false with neither is fault-shaped',
        'behaviour','GREEN','every refusal site types itself, every returned code is registered, and a live refusal matches its registered sqlstate ('||(r->>'sqlstate')||')');
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-15','every refusal carries a registered code and sqlstate','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-16 · class 2B in the refusal classifier ════════════════════════════
DO $$
DECLARE n int; teaches text; plane text; st text; raised text;
BEGIN
  SELECT count(*), max(r.teaches), max(r.plane) INTO n, teaches, plane
    FROM ckp.refusal_registry r WHERE r.sqlstate LIKE '2B%';
  IF n = 0 THEN
    PERFORM tdd('C-16','the registry carries class 2B, and it names a refusal the substrate can actually raise',
      'behaviour','RED','no 2B code registered; pgRDF advises adding it and treating anything not class XX as a refusal'); RETURN;
  END IF;

  -- CONTROL: a registered code that names no reachable refusal is worse than an
  -- absent one — it tells a classifier to expect something that never comes.
  -- Trigger the real condition and read the sqlstate the engine actually raises.
  BEGIN
    DECLARE g bigint;
    BEGIN
      SELECT graph_id INTO g FROM pgrdf._pgrdf_graphs gg
       WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id=gg.graph_id AND q.is_inferred) LIMIT 1;
      IF g IS NULL THEN raised := 'no-fixture'; ELSE
        BEGIN
          PERFORM pgrdf.drop_graph(g, false);
          raised := 'none';                    -- it SUCCEEDED: the condition is gone
        EXCEPTION WHEN OTHERS THEN
          GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE; raised := st;
        END;
        RAISE EXCEPTION 'rollback';            -- never actually drop anything
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    IF raised IS NULL THEN raised := 'probe-failed'; END IF;
  END;

  IF teaches IS NULL OR plane IS NULL THEN
    PERFORM tdd('C-16','the registry carries class 2B, and it names a refusal the substrate can actually raise',
      'behaviour','RED','2B registered without a teaches or a plane — a code that does not teach is a bare error');
  ELSIF raised = 'no-fixture' THEN
    PERFORM tdd('C-16','the registry carries class 2B, and it names a refusal the substrate can actually raise',
      'behaviour','RED','2B registered, but this database has no graph with inferred rows so the claim is UNEXERCISED — an unexercised claim is not GREEN');
  ELSIF raised NOT LIKE '2B%' THEN
    PERFORM tdd('C-16','the registry carries class 2B, and it names a refusal the substrate can actually raise',
      'behaviour','RED', format('2B registered but the real condition raised %s — the registry documents a refusal that does not occur', raised));
  ELSE
    PERFORM tdd('C-16','the registry carries class 2B, and it names a refusal the substrate can actually raise',
      'behaviour','GREEN', format('%s code(s), plane=%s, and the live condition raises %s', n, plane, raised));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-16','the registry carries class 2B','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-17 · identity triple ════════════════════════════════════════════════
DO $$
DECLARE v text; b text; e text;
BEGIN
  v := ckp.version(); b := ckp.build_id();
  SELECT extversion INTO e FROM pg_extension WHERE extname='pgck';
  IF to_regprocedure('ckp.identity_triple()') IS NULL THEN
    PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
      'existence','RED', format('no verb reports the triple. Measured by hand now: version=%s extversion=%s build_id=%s. pgRDF: a stale .so and a pre-tag artifact have both been caught ONLY by this triple', v, e, b));
  ELSE
    -- Prove DETECTION, not reporting: the comparator is pure, so feed it a
    -- mismatched pair and a missing plane. The live verb must use the SAME
    -- comparator (one rule, two callers) or the proof would be about a copy.
    DECLARE t jsonb; mis jsonb; unm jsonb; d text;
    BEGIN
      t   := ckp.identity_triple();
      mis := ckp._identity_agreement('0.0.1','0.0.2','tdd');
      unm := ckp._identity_agreement(NULL, e, b);
      SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='ckp' AND p.proname='identity_triple' LIMIT 1;
      IF (mis->>'agreement')::boolean IS NOT FALSE OR mis->'divergence' IS NULL THEN
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','RED','a mismatched pair did not report agreement:false with the divergence named — it reports, it does not detect');
      ELSIF unm->>'agreement' IS NOT NULL THEN
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','RED','an unreadable plane did not refuse agreement — it fabricated a verdict it cannot show');
      ELSIF d NOT LIKE '%_identity_agreement%' THEN
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','RED','the live verb does not call the comparator the proof exercised — a probe of a copy proves the copy');
      ELSIF NOT (t ? 'version' AND t ? 'extversion' AND t ? 'build_id' AND t ? 'agreement') THEN
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','RED','the triple is incomplete: '||t::text);
      ELSIF (t->>'agreement')::boolean IS DISTINCT FROM (v = e) THEN
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','RED','the live verdict disagrees with a hand comparison of the same planes: '||t::text);
      ELSE
        PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
          'behaviour','GREEN', format('triple complete (%s/%s/%s), live verdict %s matches hand comparison; a forced mismatch reports false naming both planes; a missing plane refuses a verdict',
            t->>'version', t->>'extversion', t->>'build_id', t->>'state'));
      END IF;
    END;
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-17','a verb reports version/build_id/extversion together','existence','BROKEN',SQLERRM);
END $$;

-- ═══ D-1 · adoption_pins digests carry their method ════════════════════════
DO $$
DECLARE unlabelled int; planes_differ int; canon_ok int; canon_present int; fx text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                 WHERE table_schema='ckp' AND table_name='adoption_pins' AND column_name='methods') THEN
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','RED','adoption_pins has NO methods column — a reader cannot tell drift from a method difference');
    RETURN;
  END IF;

  -- FIXTURE, learned from C-13 AND from this probe's own first run: do not let
  -- ambient data decide the verdict. A fresh database has no pins, and the first
  -- fixture picked graph_id 0 — which is EMPTY, so the copy plane and RDFC both
  -- returned sha256("") and coincided. The control correctly refused to certify
  -- a method label it could not show was load-bearing. Pin a graph WITH CONTENT.
  -- ⚠ FIXTURE HYGIENE. The first version inserted a pin and never removed it, so
  -- pins accumulated across runs and one eventually went STALE as a later probe
  -- changed the graph beneath it — D-1 then reported RED for a real disagreement
  -- that this file had manufactured. The detector was right; the fixture was
  -- dirty. Record what we insert and remove it before judging.
  IF to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL THEN
    SELECT g.iri INTO fx FROM pgrdf._pgrdf_graphs g
     WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = g.graph_id)
       AND NOT EXISTS (SELECT 1 FROM ckp.adoption_pins ap WHERE ap.graph_iri = g.iri)
     ORDER BY g.graph_id LIMIT 1;
    INSERT INTO ckp.adoption_pins(graph_iri, graph_digest, structural_digest,
                                  canonical_digest, methods, nodeshapes, properties, asserted)
    SELECT g.iri,
           ckp._surface_digest(g.graph_id),
           pgrdf.structural_digest(g.graph_id),
           pgrdf.graph_digest(g.graph_id),
           jsonb_build_object('graph_digest','ckp-copy-sha256',
                              'structural_digest','pgrdf-fd1-sha256',
                              'canonical_digest','rdfc-1.0-sha256'),
           0, 0, 0
      FROM pgrdf._pgrdf_graphs g
     WHERE EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q WHERE q.graph_id = g.graph_id)
       -- and NOT already pinned, or ON CONFLICT DO NOTHING silently skips and
       -- leaves the canonical column unexercised. That happened on the first run
       -- and the probe reported GREEN on a column nothing had ever written.
       AND NOT EXISTS (SELECT 1 FROM ckp.adoption_pins ap WHERE ap.graph_iri = g.iri)
     ORDER BY g.graph_id LIMIT 1
    ON CONFLICT (graph_iri) DO NOTHING;
  END IF;

  -- (a) POSITIVE: no stored digest lacks a method
  SELECT count(*) INTO unlabelled FROM ckp.adoption_pins
   WHERE (graph_digest      IS NOT NULL AND methods->>'graph_digest'      IS NULL)
      OR (structural_digest IS NOT NULL AND methods->>'structural_digest' IS NULL)
      OR (canonical_digest  IS NOT NULL AND methods->>'canonical_digest'  IS NULL);

  -- (b) THE CONTROL: the planes must be genuinely DIFFERENT computations. If the
  -- copy plane and the canonical plane ever agreed, the method label would be
  -- decoration and (a) would pass while proving nothing.
  SELECT count(*) INTO planes_differ FROM ckp.adoption_pins p
    JOIN pgrdf._pgrdf_graphs g ON g.iri = p.graph_iri
   WHERE to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL
     AND p.graph_digest IS DISTINCT FROM pgrdf.graph_digest(g.graph_id)
     AND p.structural_digest = pgrdf.structural_digest(g.graph_id);

  -- (c) where a canonical digest was recorded it must AGREE with the engine —
  -- that is the whole point of adding a plane two parties can compare.
  SELECT count(*) FILTER (WHERE p.canonical_digest IS NOT NULL),
         count(*) FILTER (WHERE p.canonical_digest = pgrdf.graph_digest(g.graph_id))
    INTO canon_present, canon_ok
    FROM ckp.adoption_pins p JOIN pgrdf._pgrdf_graphs g ON g.iri = p.graph_iri
   WHERE to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL;

  -- remove the fixture BEFORE judging, so this run cannot poison the next
  IF fx IS NOT NULL THEN DELETE FROM ckp.adoption_pins WHERE graph_iri = fx; END IF;

  IF unlabelled > 0 THEN
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','RED', unlabelled||' stored digest(s) carry no method');
  ELSIF planes_differ = 0 THEN
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','RED','control did not hold: no pinned graph shows copy-plane disagreement with fd1 agreement, so nothing here proves the planes are distinct');
  ELSIF canon_present = 0 THEN
    -- REQUIRED, not optional. The claim includes "the comparable plane agrees
    -- with the engine"; with no canonical pin anywhere that half is unexercised,
    -- and an unexercised half cannot be GREEN. This exact hole granted a false
    -- GREEN on the first run.
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','RED','no pin carries a canonical digest — the plane two parties can actually compare is unexercised, so the claim is half unproven');
  ELSIF canon_ok <> canon_present THEN
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','RED', format('%s of %s canonical digest(s) disagree with the engine — the comparable plane is not comparable', canon_present-canon_ok, canon_present));
  ELSE
    PERFORM tdd('D-1','every stored digest carries its METHOD, so a mismatch means drift and never a method confusion',
      'behaviour','GREEN', format('every digest labelled; %s pin(s) prove the planes are distinct (copy disagrees, fd1 agrees); %s canonical pin(s) agree with the engine', planes_differ, canon_ok));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('D-1','every stored digest carries its METHOD','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ E-1 · an epoch can be checked against the surface it ran under ════════
DO $$
DECLARE has_col bool; shape_demands int; agree int; disagree int; unsealed int;
BEGIN
  SELECT EXISTS(SELECT 1 FROM information_schema.columns
                 WHERE table_schema='ckp' AND table_name='kernel_epoch'
                   AND column_name ILIKE '%surface%') INTO has_col;
  -- CONTROL: the class must really demand it, or this is a misreading of the law.
  SELECT count(*) INTO shape_demands FROM pgrdf.sparql(
    'PREFIX sh: <http://www.w3.org/ns/shacl#>
     PREFIX ckp: <https://conceptkernel.org/ontology/v3.11/core#>
     SELECT ?b WHERE { GRAPH <urn:ckp:core> {
       ckp:EpochShape sh:property ?b . ?b sh:path ckp:surfaceDigest ; sh:minCount 1 } }');
  IF shape_demands = 0 THEN
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','BROKEN','control failed: EpochShape does not demand surfaceDigest here — the premise is wrong, not the table'); RETURN;
  END IF;
  IF NOT has_col THEN
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','RED','ckp.kernel_epoch is (kernel, epoch) with NO surface column while EpochShape demands surfaceDigest minCount 1 — the table is weaker than the class it seals against'); RETURN;
  END IF;

  -- POSITIVE: where a sealed Epoch exists, the row must AGREE with it.
  -- CONTROL: where none exists the row must be NULL, not a value invented now.
  SELECT count(*) FILTER (WHERE ke.surface_digest = e.sd),
         count(*) FILTER (WHERE e.sd IS NOT NULL AND ke.surface_digest IS DISTINCT FROM e.sd),
         count(*) FILTER (WHERE e.sd IS NULL AND ke.surface_digest IS NOT NULL)
    INTO agree, disagree, unsealed
    FROM ckp.kernel_epoch ke
    LEFT JOIN (SELECT substring(i.body->>'https://conceptkernel.org/ontology/v3.11/core#producedBy'
                                from '^urn:ckp:([a-z0-9-]+)/kernel/ck$') k,
                      (i.body->>'https://conceptkernel.org/ontology/v3.11/core#epoch')::int ep,
                      i.body->>'https://conceptkernel.org/ontology/v3.11/core#surfaceDigest' sd
                 FROM ckp.instances i
                WHERE i.body->>'type'='https://conceptkernel.org/ontology/v3.11/core#Epoch') e
      ON e.k = ke.kernel AND e.ep = ke.epoch;

  IF disagree > 0 THEN
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','RED', disagree||' row(s) disagree with the sealed Epoch — the table drifted from the seal, which is the failure the shared variable exists to prevent');
  ELSIF unsealed > 0 THEN
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','RED', unsealed||' row(s) carry a digest with NO sealed Epoch behind it — a value invented for a moment nobody measured');
  ELSIF agree = 0 THEN
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','RED','column present but NO row agrees with a sealed Epoch — the claim is unexercised, which is not GREEN');
  ELSE
    PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under, as EpochShape demands',
      'behaviour','GREEN', agree||' row(s) agree with their sealed Epoch; none invented where nothing was sealed');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('E-1','an epoch in ckp.kernel_epoch carries the surfaceDigest it ran under','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ E-2 · the roster reconciles all three populations ═════════════════════
-- The diagnosability gap behind pgRDF's §4. They asked "why do we have no
-- /instances graph" and could not answer it from their side. The answer is that
-- pgrdf is in neither the GUC nor the ledger — never germinated, and unable to
-- germinate because reaching the door requires being rostered. Nothing reports
-- that, so the question could only be asked of us.
DO $$
DECLARE r jsonb; ghosts int;
BEGIN
  IF to_regprocedure('ckp.roster()') IS NULL THEN
    PERFORM tdd('E-2','the roster reconciles sealed, rostered and graph-bearing kernels, so a kernel with no graph can learn why',
      'behaviour','RED','ckp.roster() absent'); RETURN;
  END IF;
  r := ckp.roster();
  -- CONTROL: a live specimen must exist, or an absent key proves nothing.
  SELECT count(*) INTO ghosts FROM (
    SELECT DISTINCT substring(iri from '^urn:ckp:([a-z0-9-]+)/') k
      FROM pgrdf._pgrdf_graphs WHERE iri LIKE 'urn:ckp:%/%'
    EXCEPT SELECT unnest(ckp._ledger_kernels())) x WHERE k IS NOT NULL;

  IF NOT (r ? 'gucOnly') OR NOT (r ? 'ghosts') THEN
    PERFORM tdd('E-2','the roster reconciles sealed, rostered and graph-bearing kernels, so a kernel with no graph can learn why',
      'behaviour','RED', format('roster() reports guc/ledger/union/ledgerOnly and NOT gucOnly (rostered, never sealed) or ghosts (graphs, no sealed kernel). %s live ghost(s) exist that it cannot name', ghosts));
  ELSIF ghosts > 0 AND jsonb_array_length(r->'ghosts') <> ghosts THEN
    PERFORM tdd('E-2','the roster reconciles sealed, rostered and graph-bearing kernels, so a kernel with no graph can learn why',
      'behaviour','RED', format('roster() reports %s ghost(s), %s exist', jsonb_array_length(r->'ghosts'), ghosts));
  ELSE
    PERFORM tdd('E-2','the roster reconciles sealed, rostered and graph-bearing kernels, so a kernel with no graph can learn why',
      'behaviour','GREEN', format('all three populations reconciled; %s ghost(s) named', ghosts));
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('E-2','the roster reconciles sealed, rostered and graph-bearing kernels','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ E-3 · undeclared keys are refused in EVERY form ═══════════════════════
-- Found while fixing s81's control (e), which had passed for the wrong reason —
-- an unattributed-identity refusal, not an undeclared-field one. With an identity
-- named, the truth appeared: update_typed refuses a BARE undeclared key and
-- ACCEPTS the same property spelled as a full IRI. A caller who writes the
-- namespace out can mint any property onto a sealed instance, and nothing
-- refuses it — no shape targets a property that does not exist, so it conforms
-- vacuously. This is the trap the composed-aware patch path was built to close,
-- surviving inside it.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#'; kid text;
        r_bare jsonb; r_iri jsonb; r_good jsonb;
BEGIN
  PERFORM set_config('ckp.requester','svc:tdd-e3',true);
  SELECT body->>'@id' INTO kid FROM ckp.instances WHERE body->>'type'=C||'Kernel' ORDER BY ts_created LIMIT 1;
  IF kid IS NULL THEN
    -- BUILD THE FIXTURE rather than reporting BROKEN. A database with no sealed
    -- Kernel is an ordinary state (a fresh install, or a gate mid-rebuild), not a
    -- broken test — and a probe that cannot run on a clean database can only ever
    -- report on databases somebody else prepared. Same lesson as C-13 and D-1.
    INSERT INTO ckp.instances(id, body) VALUES
      ('tdd-e3-kernel', jsonb_build_object('@id','urn:ckp:tdde3/kernel','type',C||'Kernel',
        'http://www.w3.org/2000/01/rdf-schema#label','e3',
        C||'epoch',0, C||'inProject','urn:ckp:project:tdde3', C||'transportSegment','tdde3',
        C||'hasOrgan', jsonb_build_array('urn:ckp:tdde3/organ/ck','urn:ckp:tdde3/organ/tool','urn:ckp:tdde3/organ/data')))
      ON CONFLICT (id) DO NOTHING;
    -- the BARE id, because update_typed looks up ckp.instances.id and does NOT
    -- resolve id forms — unlike instance.get after E-3's own fix. That asymmetry
    -- is filed as E-5; here we simply use the form this verb accepts.
    kid := 'tdd-e3-kernel';
  END IF;
  r_bare := ckp.update_typed(jsonb_build_object('id',kid,'patch',jsonb_build_object('e3NonsenseBare',0.5)));
  r_iri  := ckp.update_typed(jsonb_build_object('id',kid,'patch',jsonb_build_object(C||'e3NonsenseIri',0.5)));
  -- CONTROL: a DECLARED property in full-IRI form must still be ACCEPTED, or the
  -- cure is "refuse every IRI", which breaks every legitimate patch.
  r_good := ckp.update_typed(jsonb_build_object('id',kid,'patch',jsonb_build_object(C||'weightAssent',1.0)));

  IF (r_bare->>'ok')::boolean IS TRUE THEN
    PERFORM tdd('E-3','an undeclared property is refused in EVERY key form — bare, CURIE and full IRI',
      'behaviour','RED','even a BARE undeclared key was accepted — the gate is gone entirely');
  ELSIF (r_iri->>'ok')::boolean IS TRUE THEN
    PERFORM tdd('E-3','an undeclared property is refused in EVERY key form — bare, CURIE and full IRI',
      'behaviour','RED','bare form refused ('||COALESCE(r_bare->>'error','?')||') and the SAME property in full-IRI form ACCEPTED — spelling out the namespace bypasses the gate');
  ELSIF (r_good->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('E-3','an undeclared property is refused in EVERY key form — bare, CURIE and full IRI',
      'behaviour','RED','control failed: a DECLARED property in full-IRI form was also refused ('||COALESCE(r_good->>'error','?')||') — the cure refuses everything, which is a wall not a gate');
  ELSE
    PERFORM tdd('E-3','an undeclared property is refused in EVERY key form — bare, CURIE and full IRI',
      'behaviour','GREEN','undeclared refused in both forms; a declared full-IRI property still accepted');
  END IF;
  BEGIN DELETE FROM ckp.instances WHERE id='tdd-e3-kernel'; EXCEPTION WHEN OTHERS THEN NULL; END;
  IF FALSE THEN
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('E-3','an undeclared property is refused in EVERY key form','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ E-4 · ownership cannot be taken by a non-owner ════════════════════════
-- Found while answering whether a kernel can be handed to another party. It
-- cannot — and worse, it can be TAKEN. ckp:ownedBy is an ordinary declared
-- property of ckp:Project, so instance.update patches it like any other. Both
-- guards that read it are therefore bypassable in one step: re-own the Project,
-- then apply (C-2) or re-germinate (0.4.89) freely. germinate's own comment
-- calls ownedBy "the triple a client cannot write". A client can.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#'; r jsonb; before text; after text;
BEGIN
  PERFORM set_config('ckp.requester','svc:tdd-e4-attacker',true);
  INSERT INTO ckp.instances(id, body) VALUES
    ('tdd-e4-proj', jsonb_build_object('@id','urn:ckp:project:tdde4','type',C||'Project',
       'http://www.w3.org/2000/01/rdf-schema#label','E4','urn:x','x',
       C||'projectKind','shared', C||'ownedBy','urn:ckp:participant:tdd-e4-owner'))
    ON CONFLICT (id) DO NOTHING;
  SELECT body->>(C||'ownedBy') INTO before FROM ckp.instances WHERE id='tdd-e4-proj';
  r := ckp.update_typed(jsonb_build_object('id','tdd-e4-proj',
         'patch', jsonb_build_object(C||'ownedBy','urn:ckp:participant:tdd-e4-attacker')));
  SELECT body->>(C||'ownedBy') INTO after FROM ckp.instances WHERE id='tdd-e4-proj';
  DELETE FROM ckp.instances WHERE id='tdd-e4-proj';
  IF before IS NULL THEN
    PERFORM tdd('E-4','ckp:ownedBy cannot be rewritten by a party who is not the owner',
      'behaviour','BROKEN','fixture did not seal an owner');
  ELSIF after IS DISTINCT FROM before THEN
    PERFORM tdd('E-4','ckp:ownedBy cannot be rewritten by a party who is not the owner',
      'behaviour','RED','a NON-OWNER rewrote ownedBy through instance.update ('||before||' -> '||after||'). Both the germinate guard and the apply gate read this field, so both are bypassable in one step');
  ELSE
    PERFORM tdd('E-4','ckp:ownedBy cannot be rewritten by a party who is not the owner',
      'behaviour','GREEN','a non-owner could not rewrite ownedBy');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.instances WHERE id='tdd-e4-proj'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('E-4','ckp:ownedBy cannot be rewritten by a party who is not the owner','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ E-5 · one id vocabulary across the verbs ══════════════════════════════
-- instance.get resolves bare, ckp://Type#id and urn: forms since 0.4.90 (E-3's
-- sibling fix). update_typed resolves NONE of them — it looks up ckp.instances.id
-- directly. So a caller who takes the @id from a create reply can READ with it
-- and cannot PATCH with it, and the refusal is `unknown_instance`, which says the
-- thing does not exist rather than that the spelling is wrong.
DO $$
DECLARE C text := 'https://conceptkernel.org/ontology/v3.11/core#'; r_bare jsonb; r_atid jsonb;
BEGIN
  PERFORM set_config('ckp.requester','svc:tdd-e5',true);
  INSERT INTO ckp.instances(id, body) VALUES
    ('tdd-e5-k', jsonb_build_object('@id','urn:ckp:tdde5/kernel','type',C||'Kernel',
        'http://www.w3.org/2000/01/rdf-schema#label','e5',
        C||'epoch',0, C||'inProject','urn:ckp:project:tdde5', C||'transportSegment','tdde5',
        C||'hasOrgan', jsonb_build_array('urn:ckp:tdde5/organ/ck','urn:ckp:tdde5/organ/tool','urn:ckp:tdde5/organ/data')))
    ON CONFLICT (id) DO NOTHING;
  -- patch rdfs:label — declared on KernelShape in every law revision. The first
  -- draft patched ckp:epoch, which 0.4.104 (C-13) retires from the shape: a
  -- probe keyed on a retiring term measures the rename, not the id vocabulary.
  r_bare := ckp.update_typed(jsonb_build_object('id','tdd-e5-k','patch',jsonb_build_object('http://www.w3.org/2000/01/rdf-schema#label','e5-bare')));
  r_atid := ckp.update_typed(jsonb_build_object('id','urn:ckp:tdde5/kernel','patch',jsonb_build_object('http://www.w3.org/2000/01/rdf-schema#label','e5-atid')));
  DELETE FROM ckp.instances WHERE id='tdd-e5-k';
  IF (r_bare->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('E-5','every verb accepts every id form the substrate emits — read and write alike',
      'behaviour','BROKEN','the BARE form failed too: '||COALESCE(r_bare->>'error','?'));
  ELSIF (r_atid->>'ok')::boolean IS NOT TRUE THEN
    PERFORM tdd('E-5','every verb accepts every id form the substrate emits — read and write alike',
      'behaviour','RED','instance.get resolves the @id form and update_typed does not — got '||COALESCE(r_atid->>'error','?')||'. A caller can READ with the id a reply gave them and cannot PATCH with it');
  ELSE
    PERFORM tdd('E-5','every verb accepts every id form the substrate emits — read and write alike',
      'behaviour','GREEN','bare and @id forms both patch');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.instances WHERE id='tdd-e5-k'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('E-5','every verb accepts every id form the substrate emits','behaviour','BROKEN',SQLERRM);
END $$;
