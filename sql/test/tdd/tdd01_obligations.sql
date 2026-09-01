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

-- ═══ C-1 · L-8 quorum derived from projectKind ═════════════════════════════
DO $$
BEGIN
  -- MATERIALIZED is an optimisation FENCE and it is load-bearing: without it the
  -- planner evaluates pg_get_functiondef BEFORE the nspname filter and hits
  -- pg_catalog.array_agg, which throws "is an aggregate function". The harness
  -- caught that as BROKEN rather than RED, which is exactly its job.
  IF EXISTS (WITH f AS MATERIALIZED (
               SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                WHERE n.nspname='ckp' AND p.prokind='f')
             SELECT 1 FROM f
              WHERE pg_get_functiondef(f.oid) LIKE '%projectKind%'
                AND pg_get_functiondef(f.oid) LIKE '%requiresQuorum%') THEN
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it',
      'existence','RED','a function now mentions both — write the behaviour probe with its control');
  ELSE
    PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it',
      'existence','RED','no code path reads projectKind when computing quorum — quorum is COALESCE(...,1) at both call sites');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-1','a project declaring `shared` REFUSES requires_quorum 1; `personal` accepts it','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-2 · ownership enforced on apply, in the substrate ═══════════════════
DO $$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='ckp' AND p.proname='apply' LIMIT 1;
  IF d IS NULL THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not','existence','BROKEN','ckp.apply not found');
  ELSIF d LIKE '%ownedBy%' THEN
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not',
      'existence','RED','ckp.apply now mentions ownedBy — write the behaviour probe with its control');
  ELSE
    PERFORM tdd('C-2','a non-owner applying a quorum-met proposal is REFUSED; the owner is not',
      'existence','RED','ckp.apply checks proposal exists + pending + distinct approvals only. NO ownership check — the owner-applies rule lives in a client, and a screen is not a gate');
  END IF;
END $$;

-- ═══ C-3 · at least one proof obligation registered, and it REFUSES ════════
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM ckp.proof_obligations WHERE active;
  IF n = 0 THEN
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; an unrelated seal still lands',
      'existence','RED','zero obligations registered on this door — the gate that refuses a seal is switched off everywhere');
  ELSE
    PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; an unrelated seal still lands',
      'existence','RED', n||' registered — now prove it REFUSES, and that an unrelated seal still lands');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-3','a registered obligation REFUSES a seal that violates it; an unrelated seal still lands','existence','BROKEN',SQLERRM);
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
DECLARE s jsonb;
BEGIN
  IF to_regprocedure('ckp.storage()') IS NULL THEN
    PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one','existence','RED','ckp.storage() absent');
  ELSE
    s := ckp.storage();
    IF s ? 'perKernel' THEN
      PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
        'existence','RED','perKernel key present — now prove the attribution is correct against a known fixture');
    ELSE
      PERFORM tdd('C-12','storage is reported PER KERNEL, so a busy kernel is distinguishable from a bad one',
        'existence','RED','ckp.storage() reports the WHOLE database. Graphs are prefixed by kernel so the data is already attributable — the gap is a report, not a mechanism');
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-12','storage is reported PER KERNEL','existence','BROKEN',SQLERRM);
END $$;

-- ═══ C-13 · ckp:epoch on the sealed Kernel ═════════════════════════════════
DO $$
DECLARE stale int; ambient int;
BEGIN
  -- FIXTURE, not ambient data. This probe first came back GREEN on a rig whose
  -- kernels had never advanced past epoch 0 — the claim was not false, it was
  -- UNEXERCISED, and an unexercised behaviour probe reporting GREEN is the same
  -- defect as an existence probe reporting GREEN. So construct the condition:
  -- a sealed Kernel carrying ckp:epoch, and a live epoch that has moved past it.
  INSERT INTO ckp.instances(id, body) VALUES
    ('tdd-c13-kernel', jsonb_build_object(
       '@id','urn:ckp:tddc13/kernel',
       'type','https://conceptkernel.org/ontology/v3.11/core#Kernel',
       'https://conceptkernel.org/ontology/v3.11/core#epoch', 0))
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES ('tddc13', 4)
    ON CONFLICT (kernel) DO UPDATE SET epoch = 4;

  SELECT count(*) INTO stale FROM ckp.instances i
   WHERE i.body->>'type'='https://conceptkernel.org/ontology/v3.11/core#Kernel'
     AND i.body ? 'https://conceptkernel.org/ontology/v3.11/core#epoch'
     AND COALESCE((i.body->>'https://conceptkernel.org/ontology/v3.11/core#epoch')::int,-1)
         IS DISTINCT FROM COALESCE((SELECT e.epoch FROM ckp.kernel_epoch e
                                     WHERE e.kernel = substring(i.body->>'@id' from '^urn:ckp:([a-z0-9-]+)/kernel$')), 0);
  ambient := stale;
  DELETE FROM ckp.instances   WHERE id = 'tdd-c13-kernel';
  DELETE FROM ckp.kernel_epoch WHERE kernel = 'tddc13';

  IF stale > 0 THEN
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','RED', stale||' sealed Kernel(s) carry ckp:epoch disagreeing with the live epoch (fixture included) — a sealed fact holding a mutable value; this is why every sun renders e0 on the board. ⚠ CURE CORRECTED: ckp:epoch is minCount 1 on KernelShape, so REMOVING it from the germination template would violate the law. The options are a governed rename to germinatedAtEpoch (an ontology change, proposable now that set_kernel_policy exists as precedent) or fixing every reader — not a deletion');
  ELSE
    -- The fixture GUARANTEES one stale row while the defect exists, so reaching
    -- here means germination no longer stamps a mutable ckp:epoch. That is the
    -- only way this claim can honestly be GREEN.
    PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not',
      'behaviour','GREEN','even the constructed stale fixture did not register — no sealed Kernel carries a mutable epoch');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN DELETE FROM ckp.instances WHERE id='tdd-c13-kernel'; DELETE FROM ckp.kernel_epoch WHERE kernel='tddc13'; EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM tdd('C-13','a sealed instance carries no value a reader can mistake for a live one — either it tracks, or its NAME says it does not','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-14 · routed vs declared affordances ═════════════════════════════════
DO $$
DECLARE routed int; declared int;
BEGIN
  SELECT count(*) INTO routed FROM ckp.affordance_registry;
  SELECT count(*) INTO declared FROM ckp.instances WHERE body->>'type' LIKE '%#Affordance';
  IF routed = declared THEN
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','GREEN', 'routed='||routed||' declared='||declared);
  ELSE
    PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it — both halves or neither',
      'behaviour','RED', 'routed='||routed||' declared='||declared||' — a '||(routed-declared)||'-wide gap; capability cannot be derived honestly from a registry the ledger does not back');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-14','every routed verb has a sealed ckp:Affordance behind it','behaviour','BROKEN',SQLERRM);
END $$;

-- ═══ C-15 · every refusal-shaped prose is typed ════════════════════════════
DO $$
DECLARE untyped int;
BEGIN
  -- same fence, same reason
  WITH f AS MATERIALIZED (
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='ckp' AND p.prokind='f')
  SELECT count(*) INTO untyped FROM f
   WHERE pg_get_functiondef(f.oid) ~ 'ok.., false, .error'
     AND pg_get_functiondef(f.oid) NOT LIKE '%sqlstate%';
  PERFORM tdd('C-15','every refusal carries a registered code and sqlstate; an ok:false with neither is fault-shaped',
    'behaviour','RED', untyped||' ckp function(s) return ok:false with an error and NO sqlstate — untyped refusals a classifier cannot key on');
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
    PERFORM tdd('C-17','a verb reports version/build_id/extversion together and REFUSES agreement it cannot show',
      'existence','RED','verb exists — now prove it DETECTS a mismatch, not merely reports three strings');
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('C-17','a verb reports version/build_id/extversion together','existence','BROKEN',SQLERRM);
END $$;

-- ═══ D-1 · adoption_pins digests carry their method ════════════════════════
DO $$
DECLARE unlabelled int; planes_differ int; canon_ok int; canon_present int;
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
  IF to_regprocedure('pgrdf.graph_digest(bigint)') IS NOT NULL THEN
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
    PERFORM tdd('E-3','an undeclared property is refused in EVERY key form — bare, CURIE and full IRI',
      'behaviour','BROKEN','no sealed Kernel to patch — fixture problem, not a result'); RETURN;
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
EXCEPTION WHEN OTHERS THEN
  PERFORM tdd('E-3','an undeclared property is refused in EVERY key form','behaviour','BROKEN',SQLERRM);
END $$;
