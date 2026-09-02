-- s85_affordance_both_halves.sql — BOTH HALVES OR NEITHER (0.4.105).
--
-- routes: a row in ckp.affordance_registry. declared: a sealed ckp:Affordance.
-- One without the other grows the #56 gap. The backfill closes it for every
-- GERMINATED kernel — a kernel with no kernel graph is a seed routing row, not
-- a real kernel, and declaring its capability (or composing its surface, which
-- would steal the bootstrap graph id) would be premature. This gate germinates
-- a real fixture kernel, gives it a routed verb, and proves the closure, the
-- resolving derivedBy chain, the routing→root plane mapping, and idempotence.
\set ON_ERROR_STOP 1

DO $$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  r jsonb; v_aff jsonb; n int;
BEGIN
  PERFORM set_config('ckp.requester','svc:s85',true);

  -- FIXTURE: a real germinated kernel with one routed verb.
  DELETE FROM ckp.affordance_registry WHERE kernel='s85k';
  r := ckp.germinate_kernel('s85k','s85','personal');
  IF (r->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 's85 FIXTURE FAIL — germination refused: %', r; END IF;
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, out_topic, plane, delegate)
  VALUES ('s85k','s85.probe','input.kernel.s85k.action.s85.probe','result.kernel.s85k.s85.probe','query',false);

  -- (a) the verb is routed and NOT yet declared — the gap, constructed.
  SELECT count(*) INTO n FROM ckp.instances WHERE id='aff-s85k-s85-probe';
  IF n <> 0 THEN RAISE EXCEPTION 's85 (a) FAIL — the fixture verb is already declared; the gap was not constructed'; END IF;
  RAISE NOTICE 's85 (a) PASS — a routed verb exists with no sealed Affordance: the gap';

  -- (b) the backfill closes it, and the seal carries the row's truth: plane
  -- mapped to the root's closed vocabulary, and a derivedBy that RESOLVES
  -- through Materialization to a sealed Epoch (the law demands it minCount 1).
  r := ckp.declare_routed_affordances();
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->'failed')::text <> '[]' THEN
    RAISE EXCEPTION 's85 (b) FAIL — backfill reported failures: %', r; END IF;
  SELECT i.body INTO v_aff FROM ckp.instances i WHERE i.id='aff-s85k-s85-probe';
  IF v_aff IS NULL THEN RAISE EXCEPTION 's85 (b) FAIL — the routed verb did not seal'; END IF;
  IF v_aff->>(C||'plane') IS DISTINCT FROM 'derived' THEN
    RAISE EXCEPTION 's85 (b) FAIL — routing plane query must seal as root ''derived'', got %', v_aff->>(C||'plane'); END IF;
  IF v_aff->>(C||'inTopic') IS DISTINCT FROM 'input.kernel.s85k.action.s85.probe' THEN
    RAISE EXCEPTION 's85 (b) FAIL — sealed inTopic disagrees with the registry row'; END IF;
  IF v_aff->>(C||'derivedBy') IS NULL THEN
    RAISE EXCEPTION 's85 (b) FAIL — no derivedBy: the law demands the deriving act be named'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ckp.instances i
                  WHERE i.body->>'@id' = v_aff->>(C||'derivedBy') AND i.body->>'type' = C||'Materialization') THEN
    RAISE EXCEPTION 's85 (b) FAIL — derivedBy cites %, not a sealed Materialization: a phantom citation', v_aff->>(C||'derivedBy'); END IF;
  IF NOT EXISTS (SELECT 1 FROM ckp.instances m
                  JOIN ckp.instances e ON e.body->>'@id' = m.body->>(C||'producesEpoch') AND e.body->>'type' = C||'Epoch'
                  WHERE m.body->>'@id' = v_aff->>(C||'derivedBy')) THEN
    RAISE EXCEPTION 's85 (b) FAIL — the Materialization''s producesEpoch does not resolve to a sealed Epoch'; END IF;
  RAISE NOTICE 's85 (b) PASS — the route sealed with the row''s truth; query→derived; derivedBy→Materialization→Epoch all resolve';

  -- (c) IDEMPOTENT: a second run seals nothing.
  r := ckp.declare_routed_affordances();
  IF (r->>'sealed')::int <> 0 THEN
    RAISE EXCEPTION 's85 (c) FAIL — a second run sealed %: not idempotent', r->>'sealed'; END IF;
  RAISE NOTICE 's85 (c) PASS — a second run seals zero: the closure holds';

  -- (d) an ungerminated seed kernel is SKIPPED, not stolen-from: prove no
  -- graph was created for a kernel that had none (the bootstrap-slot defect).
  DELETE FROM ckp.affordance_registry WHERE kernel='s85ghost';
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane)
  VALUES ('s85ghost','s85.ghost','input.kernel.s85ghost.action.s85.ghost','instance');
  r := ckp.declare_routed_affordances();
  IF EXISTS (SELECT 1 FROM pgrdf._pgrdf_graphs WHERE iri='urn:ckp:s85ghost/kernel/ck') THEN
    RAISE EXCEPTION 's85 (d) FAIL — the backfill created a kernel graph for an ungerminated kernel: the bootstrap-slot theft'; END IF;
  IF EXISTS (SELECT 1 FROM ckp.instances WHERE id='aff-s85ghost-s85-ghost') THEN
    RAISE EXCEPTION 's85 (d) FAIL — an ungerminated kernel''s verb was declared: premature capability'; END IF;
  RAISE NOTICE 's85 (d) PASS — an ungerminated seed kernel is skipped, its graph never created';

  DELETE FROM ckp.affordance_registry WHERE kernel IN ('s85k','s85ghost');
  DELETE FROM ckp.instances WHERE id IN ('aff-s85k-s85-probe','mat-s85k-aff-backfill-0','epoch-s85k-0');
  DELETE FROM ckp.kernel_epoch WHERE kernel IN ('s85k','s85ghost');
END $$;

\echo 's85 PASS — a germinated kernel''s routes declare with a resolving chain, idempotently; seed kernels are skipped'
