-- s76_germinate_ownership_guard.sql — A DESTRUCTIVE ACT MUST BE REFUSED, NOT MERELY RECORDED (0.4.89).
--
-- WHY THIS EXISTS. ckp.germinate_kernel calls pgrdf.clear_graph() on the kernel
-- graph and then re-seals ckp:ownedBy from the CALLING connection. Until 0.4.89
-- nothing refused a SECOND germination by a party that does not own the project.
-- Measured the same day (read-only, on the wire): auth_callout::permissions_for
-- mints publish on input.kernel.<k>.id.<own-sub>.action.> for EVERY kernel in the
-- roster, so every verified identity on a door holds publish on every rostered
-- segment — bot-ck-dev dispatched successfully via gov=pgck on a door where ck-dev
-- was in neither half of the roster union. Any bot could therefore wipe a live
-- kernel's graph and stamp itself as its owner.
--
-- The four stamps would have recorded that truthfully. THAT IS NOT ENOUGH:
-- attribution is a record, refusal is a gate, and a destructive act needs the gate.
-- Sealed as finding-1788052032938005000; the amendment it blocks is
-- finding-1788051883233705000 (the roster union cannot bootstrap first existence,
-- and the obvious cure — self-grants on your own segment — is only safe once
-- re-germination is gated).
--
-- WHAT THIS FILE PINS, both halves, because a guard that refuses EVERYONE is a
-- wall and not a gate:
--   (b) a stranger re-germinating an owned kernel is REFUSED, typed, clause named
--   (c) the OWNER re-germinating the same kernel still succeeds  [NEGATIVE CONTROL]
--   (d) the refused attempt left the graph and the ownership INTACT
--
-- STRUCTURE NOTE (inherited from s74): each act is its own top-level statement.
-- Wrapped in one DO block they share a transaction and a read-back can return the
-- pre-state, which reads exactly like the defect this test exists to catch.

-- (a) POSITIVE — alice germinates. She is the owner from here on.
SELECT set_config('ckp.requester', 's76-alice', false);
SELECT ckp.germinate_kernel('s76-probe', 'S76 Ownership Probe', 'shared') AS s76_a_germinate;

-- (b) THE GUARD — mallory, a different verified identity, tries to take it over.
SELECT set_config('ckp.requester', 's76-mallory', false);
SELECT ckp.germinate_kernel('s76-probe', 'S76 Taken Over By Mallory', 'shared') AS s76_b_takeover;

DO $$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('ckp.requester', 's76-mallory', false);
  v_r := ckp.germinate_kernel('s76-probe', 'S76 Taken Over By Mallory', 'shared');
  IF COALESCE((v_r->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 's76 (b) FAILED — a stranger re-germinated an owned kernel. THE TAKEOVER PRIMITIVE IS BACK: %', v_r;
  END IF;
  IF COALESCE((v_r->>'refused')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 's76 (b) FAILED — refused without refused:true. A refusal that is not typed is prose: %', v_r;
  END IF;
  IF v_r->>'error' NOT ILIKE '%owned by%' THEN
    RAISE EXCEPTION 's76 (b) FAILED — the refusal does not name the owner clause: %', v_r;
  END IF;
  RAISE NOTICE 's76 (b) OK — stranger refused, clause named: %', left(v_r->>'error', 120);
END $$;

-- (c) NEGATIVE CONTROL — the OWNER may still re-germinate. A guard that also
--     refuses alice is not discriminating on identity, it is just a wall.
SELECT set_config('ckp.requester', 's76-alice', false);
DO $$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('ckp.requester', 's76-alice', false);
  v_r := ckp.germinate_kernel('s76-probe', 'S76 Ownership Probe', 'shared');
  IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 's76 (c) FAILED — the OWNER was refused. The guard is a wall, not a gate: %', v_r;
  END IF;
  RAISE NOTICE 's76 (c) OK — owner re-germination still allowed (guard discriminates on identity)';
END $$;

-- (d) the refused attempt must have changed NOTHING — graph populated, owner still alice.
DO $$
DECLARE v_owner text; v_quads bigint; v_g int;
BEGIN
  SELECT i.body->>'https://conceptkernel.org/ontology/v3.11/core#ownedBy' INTO v_owner
    FROM ckp.instances i
   WHERE i.body->>'@id' = 'urn:ckp:project:s76-probe'
     AND i.body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Project'
   ORDER BY i.ts_created DESC LIMIT 1;
  IF v_owner IS DISTINCT FROM 'urn:ckp:participant:s76-alice' THEN
    RAISE EXCEPTION 's76 (d) FAILED — ownership moved. Expected alice, found %', COALESCE(v_owner, 'NULL');
  END IF;
  v_g := pgrdf.add_graph('urn:ckp:s76-probe/kernel/ck');
  SELECT count(*) INTO v_quads FROM pgrdf._pgrdf_quads WHERE graph_id = v_g;
  IF v_quads = 0 THEN
    RAISE EXCEPTION 's76 (d) FAILED — the kernel graph is EMPTY: a refused germination still cleared it';
  END IF;
  RAISE NOTICE 's76 (d) OK — owner intact (%), graph intact (% quads)', v_owner, v_quads;
  RAISE NOTICE 's76 PASS — the takeover primitive is gated, and the owner still passes';
END $$;
