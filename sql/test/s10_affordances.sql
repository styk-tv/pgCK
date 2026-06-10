-- U2-a: affordance registration + seal gate (SPEC.PGCK.GOAL-TASK-KERNEL-BOARD-MVP.v0.3 §3, §6).
-- Acceptance: pgCK's exposed capabilities are declared in
-- examples/goal-task-board.kernel.ttl as core:Affordance instances and parsed
-- by ckp.load_kernel into the project kernel/ck graph. A well-formed affordance
-- (carrying core:inTopic) seals; a malformed one (no core:inTopic) is REJECTED
-- by ckp.seal()'s step-1 required-prop gate (AffordanceShape, sh:minCount 1 on
-- core:inTopic) and leaves no instance row.
--
-- This proves the gate fires NON-vacuously: the AffordanceShape lives in the
-- kernel/ck graph (loaded from the kernel TTL) — the graph ckp.seal() step-1
-- consults for the body's `type`. (core.ttl also ships an AffordanceShape, but
-- in the core graph, which step-1 does NOT consult — hence the kernel-TTL copy.)
--
-- Namespace: affordances are v3.8/core# (where ckp:Affordance + vocab live),
-- NOT the board's v3.7/ Goal/Task namespace.
--
-- Runs on the §9 test substrate: ck-allinone:v0.7.1 with examples/ mounted at
-- /examples; psql from a postgres:17-bookworm sidecar over the wire. The
-- ckp.load_kernel file read happens server-side in the allinone container.
--
-- Run: psql -h <allinone> -U postgres -d postgres -v ON_ERROR_STOP=1 -f sql/test/s10_affordances.sql

\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','s10-aff',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

-- Register pgCK's affordances: parse the kernel TTL into urn:ckp:s10-aff/kernel/ck.
-- (The task/goal module import inside load_kernel is best-effort; the affordance
-- gate only needs the kernel/ck graph, which load_kernel parses first.)
CALL ckp.load_kernel('/examples/goal-task-board.kernel.ttl', 's10-aff');

-- Sanity: the AffordanceShape and the registered affordances landed in kernel/ck.
DO $$
DECLARE
  v_shapes int;
  v_affs int;
BEGIN
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql($q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?s WHERE { GRAPH <urn:ckp:s10-aff/kernel/ck> {
      ?s sh:targetClass <https://conceptkernel.org/ontology/v3.8/core#Affordance> } }
  $q$) AS j;
  IF v_shapes < 1 THEN
    RAISE EXCEPTION 's10 FAIL: AffordanceShape not present in kernel/ck graph (got %)', v_shapes;
  END IF;

  SELECT count(*) INTO v_affs FROM pgrdf.sparql($q$
    SELECT ?a WHERE { GRAPH <urn:ckp:s10-aff/kernel/ck> {
      ?a a <https://conceptkernel.org/ontology/v3.8/core#Affordance> } }
  $q$) AS j;
  IF v_affs < 5 THEN
    RAISE EXCEPTION 's10 FAIL: expected >=5 registered affordances, got %', v_affs;
  END IF;
END $$;

-- (a) Well-formed affordance (carries core:inTopic) → seals + verifies.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.8/core#Affordance',
    'https://conceptkernel.org/ontology/v3.8/core#inTopic',
      'input.kernel.pgCK.action.display.broadcast',
    'https://conceptkernel.org/ontology/v3.8/core#outTopic',
      'event.kernel.pgCK.Display.theme'
  );
BEGIN
  PERFORM ckp.seal('s10-aff-ok', v_body);
  IF NOT ckp.verify('s10-aff-ok') THEN
    RAISE EXCEPTION 's10 FAIL: verify() failed for sealed affordance';
  END IF;
END $$;

-- (b) Malformed affordance (NO core:inTopic) → seal must RAISE at the step-1
-- gate and leave no row.
DO $$
DECLARE
  v_body jsonb := jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.8/core#Affordance',
    'https://conceptkernel.org/ontology/v3.8/core#outTopic',
      'event.kernel.pgCK.Display.theme'
  );
  v_caught text;
BEGIN
  BEGIN
    PERFORM ckp.seal('s10-aff-bad', v_body);
    RAISE EXCEPTION 's10 FAIL: affordance with no inTopic should have raised';
  EXCEPTION WHEN OTHERS THEN
    v_caught := SQLERRM;
  END;

  IF v_caught NOT LIKE '%fails kernel shape%' THEN
    RAISE EXCEPTION 's10 FAIL: bad affordance raised but not the seal gate: %', v_caught;
  END IF;
  IF v_caught NOT LIKE '%inTopic%' THEN
    RAISE EXCEPTION 's10 FAIL: gate did not name the missing inTopic prop: %', v_caught;
  END IF;
END $$;

-- (c) Rollback proof: bad affordance left no instance row; good one persisted.
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM ckp.instances WHERE id = 's10-aff-bad';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 's10 FAIL: bad affordance left % rows in ckp.instances', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM ckp.instances WHERE id = 's10-aff-ok';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 's10 FAIL: good affordance did not land (rows=%)', v_count;
  END IF;
END $$;

\echo s10_affordances: PASS
