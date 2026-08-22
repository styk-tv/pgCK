-- s58_identity_persistence.sql — server-derived identity on the seal path (F-A / pgCK#9,#10).
--
-- The dispatch identity that becomes a sealed instance's created_by MUST derive from the
-- VERIFIED CONNECTION — the trusted `ckp.requester` GUC that the ingress relay sets from the
-- NATS-verified bearer — NEVER from a client-supplied payload field. A forged payload {sub}
-- must be IGNORED. This is the regression proving instances are attributable and un-forgeable,
-- the floor the multi-user session protocol (SPEC.CKP.SESSION.v3.9.2) stands on.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();

-- 0.4.57 legacy-compat fixture (see s38): notify has no substrate default class; declared in the project board graph the gate consults.
DO $bfix$ DECLARE g bigint; BEGIN
  g := pgrdf.add_graph('urn:ckp:demo/kernel/board');
  PERFORM pgrdf.parse_turtle($bttl$
@prefix sh: <http://www.w3.org/ns/shacl#> .
<urn:ckp:board/Task> a <http://www.w3.org/2000/01/rdf-schema#Class> .
<urn:ckp:board/shape/Task> a sh:NodeShape ;
  sh:targetClass <urn:ckp:board/Task> ;
  sh:property [ sh:path <urn:ckp:board/task_id>         ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/title>           ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/target_kernel>   ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/part_of_goal>    ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/lifecycle_state> ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/created_at>      ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/created_by>      ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/priority>        ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/queue_seq>       ; sh:maxCount 1 ] .
<urn:ckp:board/Message> a <http://www.w3.org/2000/01/rdf-schema#Class> .
<urn:ckp:board/shape/Message> a sh:NodeShape ;
  sh:targetClass <urn:ckp:board/Message> ;
  sh:property [ sh:path <urn:ckp:board/from>       ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/to>         ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/predicate>  ; sh:minCount 1 ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/body>       ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/topic>      ; sh:maxCount 1 ] ;
  sh:property [ sh:path <urn:ckp:board/created_by> ; sh:maxCount 1 ] .
$bttl$, g, 'urn:ckp:boardfix#');
  PERFORM pgrdf.materialize(g);
END $bfix$;
GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;

INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret') ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

-- The trusted ingress (relay) sets the verified requester once, from the verified bearer.
-- A participant client cannot set this GUC (it is set inside the trusted relay, not from payload).
SELECT set_config('ckp.requester','verified-requester', false);

-- (1) task.create — a FORGED payload {sub:'attacker'} must be ignored; created_by = verified requester.
DO $$
DECLARE res jsonb; v_id text; cby text;
BEGIN
  res := ckp.dispatch('task.create',
    '{"task":{"target_kernel":"Build","title":"ship it"},"sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's58 FAIL: task.create not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'urn:ckp:board/created_by' INTO cby FROM ckp.instances WHERE id = v_id;
  IF cby = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's58 FAIL (SECURITY): forged payload sub became created_by (%) — identity MUST derive from the verified connection', cby;
  END IF;
  IF cby IS DISTINCT FROM 'urn:ckp:participant:verified-requester' THEN
    RAISE EXCEPTION 's58 FAIL: task.create created_by must be the verified requester urn:ckp:participant:verified-requester, got % (body=%)',
      cby, (SELECT body FROM ckp.instances WHERE id=v_id);
  END IF;
  RAISE NOTICE 's58 PASS: task.create created_by derives from the verified requester; forged payload sub ignored (%)', cby;
END $$;

-- (1b) instance.create — the GENERIC typed path (#26 / P0-C's exact ask: prove the
-- forged-sub ignore on instance.create itself, not only the task.create concretion).
DO $$
DECLARE res jsonb; v_id text; cby text;
BEGIN
  res := ckp.dispatch('instance.create',
    '{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"s58-generic","sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's58 FAIL: instance.create not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'urn:ckp:board/created_by' INTO cby FROM ckp.instances WHERE id = v_id;
  IF cby = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's58 FAIL (SECURITY): forged payload sub became created_by on instance.create (%)', cby;
  END IF;
  IF cby IS DISTINCT FROM 'urn:ckp:participant:verified-requester' THEN
    RAISE EXCEPTION 's58 FAIL: instance.create created_by must be urn:ckp:participant:verified-requester, got % (body=%)',
      cby, (SELECT body FROM ckp.instances WHERE id=v_id);
  END IF;
  RAISE NOTICE 's58 PASS: instance.create created_by derives from the verified requester; forged payload sub ignored (%)', cby;
END $$;

-- (2) notify (message path — the msg.by / created_by attribution) — same rule.
DO $$
DECLARE res jsonb; v_id text; cby text;
BEGIN
  -- 0.4.81: the payload NAMES its predicate. This call used to omit it and the
  -- substrate filled 'notifies' — inventing the MEANING of the edge, before
  -- validation, so MessageShape's minCount(1) on board/predicate never got to
  -- speak. The shape always demanded it; the code was papering over the shape.
  -- Omitting it now refuses, naming the clause, which is the correct answer to
  -- "what kind of link is this?" when nobody said.
  res := ckp.dispatch('notify',
    '{"type":"urn:ckp:board/Message","from":"a","to":"b","body":"hi","predicate":"notifies","sub":"attacker"}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's58 FAIL: notify not ok: %', res; END IF;
  v_id := res->>'id';
  SELECT body->>'urn:ckp:board/created_by' INTO cby FROM ckp.instances WHERE id = v_id;
  IF cby = 'urn:ckp:participant:attacker' THEN
    RAISE EXCEPTION 's58 FAIL (SECURITY): forged payload sub became message created_by (%)', cby;
  END IF;
  IF cby IS DISTINCT FROM 'urn:ckp:participant:verified-requester' THEN
    RAISE EXCEPTION 's58 FAIL: notify created_by must be the verified requester, got %', cby;
  END IF;
  RAISE NOTICE 's58 PASS: notify created_by derives from the verified requester; forged payload sub ignored (%)', cby;
END $$;
