-- pgck 0.4.98 -> 0.4.99
--
-- C-2 — OWNERSHIP ON APPLY, IN THE SUBSTRATE.
--
-- ckp.apply checked that the proposal exists, is pending, and has enough DISTINCT
-- non-anonymous approvals. That was all. The owner-applies rule lived only in a
-- client: CK-dev's Action panel offers the button to the owner and notes that
-- "a counterparty applying lands the change in THEIR graph" — which is the
-- substrate's actual behaviour showing through a screen. A screen is not a gate.
-- Any party with a credential could apply a quorum-met proposal and land somebody
-- else's governed change wherever they stood.
--
-- The distinction the code was missing: QUORUM answers "did enough parties
-- AGREE". It does not answer "may THIS party ENACT it". Those are different
-- questions and only the first was ever asked.
--
-- Bind only what declared itself, exactly as C-1's quorum floor does. If the
-- target project seals ckp:ownedBy, the applier must BE that owner. If no owner
-- is declared, nothing is imposed — inventing one for a project that never named
-- an owner would be the substrate choosing on the caller's behalf, the defect
-- 0.4.81 fixed by defaulting projectKind to NULL rather than 'personal'.
--
-- Placed BEFORE the proposal lookup, and that is design rather than convenience:
-- "may this party enact changes to this about-graph" is answerable from `about`
-- alone, and asking it first means a stranger learns nothing about whether a
-- proposal exists. An ownership refusal must not double as an existence oracle.
--
-- The refusal names the owner and offers both cures — ask the owner to apply, or
-- propose against a project you own — and says why applying from elsewhere is
-- wrong rather than merely forbidden: it would land the change in YOUR graph,
-- which is not what the voters approved.
--
-- Proof: tdd obligation C-2, three cases. A stranger is refused `not_owner`; the
-- OWNER is NOT refused for ownership (a gate, not a wall); and a project with no
-- declared owner imposes nothing.

CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_about     text := p_payload->>'about';
  v_proj      text := ckp._project();
  v_prop      jsonb;
  v_pid       text;
  v_op        text;
  v_quorum    int;
  v_approvals int;
  v_epoch     int;
  v_new_body  jsonb;
  v_ttl       text;
  v_ga        jsonb;
  v_applied   jsonb := jsonb_build_object('graph_changed', false);
BEGIN
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  -- 0.4.99 (C-2) — OWNERSHIP ON APPLY, IN THE SUBSTRATE.
  --
  -- ckp.apply checked that the proposal exists, is pending, and has enough
  -- DISTINCT non-anonymous approvals. That is all. The owner-applies rule lived
  -- only in a client — CK-dev's Action panel offers the button to the owner and
  -- notes that "a counterparty applying lands the change in THEIR graph", which
  -- is the substrate's actual behaviour showing through a screen. A screen is
  -- not a gate: any party with a credential could apply a quorum-met proposal
  -- and land somebody else's governed change wherever they stood.
  --
  -- Quorum answers "did enough parties agree". It does not answer "may THIS
  -- party enact it". Those are different questions and only the first was asked.
  --
  -- Bind only what declared itself, exactly as C-1's quorum floor does: if the
  -- target project seals ckp:ownedBy, the applier must BE that owner; if no
  -- owner is declared, nothing is imposed. Inventing an owner for a project that
  -- never named one would be the substrate choosing on the caller's behalf —
  -- the defect 0.4.81 fixed by defaulting projectKind to NULL.
  DECLARE
    v_about_proj text := substring(v_about from '^urn:ckp:([a-z0-9-]+)/');
    v_owner      text;
    v_me         text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_about_proj IS NOT NULL THEN
      SELECT i.body->>(C||'ownedBy') INTO v_owner FROM ckp.instances i
       WHERE i.body->>'@id' = 'urn:ckp:project:'||v_about_proj
         AND i.body->>'type' = C||'Project'
       ORDER BY i.ts_created DESC LIMIT 1;
      IF v_owner IS NOT NULL THEN
        v_me := CASE WHEN v_me IS NULL THEN NULL
                     ELSE 'urn:ckp:participant:'||ckp._slug(v_me) END;
        IF v_me IS DISTINCT FROM v_owner THEN
          RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
            'error', 'not_owner',
            'about', v_about, 'owner', v_owner,
            'hint', format('proposal %L targets %L, which is owned by %s. Quorum answers whether '
                           'enough parties AGREED; it does not answer whether THIS party may enact '
                           'the change. Ask the owner to apply, or propose against a project you '
                           'own. Applying from elsewhere would land this change in your own graph, '
                           'which is not what the voters approved.',
                           v_about, v_about_proj, v_owner));
        END IF;
      END IF;
    END IF;
  END;

  -- Placed BEFORE the proposal lookup deliberately. "May this party enact
  -- changes to this about-graph" is answerable from `about` alone, and asking it
  -- first means a stranger learns nothing about whether a proposal exists — an
  -- ownership refusal should not double as an existence oracle.
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 0.4.98 (C-1 / L-8): the floor binds at APPLY as well, so a proposal sealed
  -- at quorum 1 before the project declared `shared` — or before this shipped —
  -- cannot still be self-applied. GREATEST, never replacement: a proposal that
  -- asked for MORE than the floor keeps what it asked for.
  v_quorum := GREATEST(COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1),
                       ckp._quorum_floor(v_proj));
  -- 0.4.62 — QUORUM IS DISTINCT ACCOUNTABLE PARTIES. This counted VOTES: one
  -- identity voting twice was two approvals, and ckp.seal mints a FRESH
  -- anon:<uuid> per unattributed call, so N naked-path seals presented as N
  -- distinct parties — one psql caller could manufacture any quorum (ck-dev's
  -- finding-1786732252462817000; measured unexploited, 3 anon votes on 3
  -- proposals). Now: distinct createdBy, anon:* excluded — an identity nobody
  -- can be held to cannot be a party to a decision. The three historical
  -- anon-applied proposals stand as fenced history, not precedent.
  SELECT count(DISTINCT body->>(C||'createdBy')) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve'
      AND COALESCE(body->>(C||'createdBy'),'') NOT LIKE 'urn:ckp:participant:anon:%';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  v_op := v_prop->>(C||'proposalOp');

  -- 4a. GRAPH APPLY (shape ops) — translate the op into the kernel graph (the §5.2 EFFECT).
  BEGIN
    v_ttl := ckp._op_to_ttl(v_prop);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_translate_failed', 'detail', SQLERRM);
  END;
  IF v_ttl IS NOT NULL THEN
    v_ga := ckp.apply_shape_ttl(v_ttl, v_proj);
    IF (v_ga->>'ok') IS DISTINCT FROM 'true' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'graph_apply_failed', 'detail', v_ga);
    END IF;
    v_applied := jsonb_build_object('graph_changed', true, 'applied_quads', v_ga->'applied_quads');
  END IF;

  -- 4a-bis. KERNEL POLICY (0.4.95, C-4). No shape projection — _op_to_ttl returns
  -- NULL for this op and the graph is untouched. The policy lives on the SEALED
  -- Kernel instance, so it is applied as a governed patch through the same path a
  -- client would use, and that is the entire point:
  --
  --   NOTHING HERE CHECKS A RANGE. The law already declares every bound —
  --   weightAssent >= 0, weightDissent <= 0, weightImplicit in [0,1],
  --   decayLambda >= 0, thresholdDefer >= 0, and thresholdDiscard sh:lessThan
  --   thresholdPromote, which is the only cross-property invariant of the seven
  --   and the one no per-property constraint can catch. Measured on the composed
  --   surface before this was written: an in-range set conforms, and each of those
  --   four violations is refused. A projector carrying its own copy of the bounds
  --   would be a second implementation of a rule that already exists — the exact
  --   defect D-1 corrected one layer over. You do not enforce your own shape; you
  --   declare it, and the ground refuses what violates it.
  --
  --   update_typed is composed-aware, so an UNDECLARED field is refused by name
  --   (undeclared_patch_key) rather than minted, and ckp.seal runs the gate that
  --   enforces the bounds. Both halves come for free.
  IF v_op = 'set_kernel_policy' THEN
    DECLARE
      v_kid   text := 'urn:ckp:'||v_proj||'/kernel';
      -- BARE key, matching every other reader (lines 2381, 3151, 3168). The
      -- body stores proposalOp under its full IRI and proposalDetail bare; that
      -- inconsistency is noted at 2441 as a known family and is not mine to fix
      -- here — but writing C||'proposalDetail' would have silently read NULL and
      -- refused every policy proposal with "needs {field, value}".
      v_field text := v_prop->'proposalDetail'->>'field';
      v_val   jsonb := v_prop->'proposalDetail'->'value';
      v_upd   jsonb;
    BEGIN
      IF v_field IS NULL OR v_val IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch',
          'hint', 'set_kernel_policy needs {field, value}');
      END IF;
      v_upd := ckp.update_typed(jsonb_build_object(
                 'id', v_kid,
                 'patch', jsonb_build_object(C||v_field, v_val)));
      IF (v_upd->>'ok') IS DISTINCT FROM 'true' THEN
        -- the refusal travels VERBATIM. A policy refused by the shape gate must
        -- say which clause refused it, not be flattened into "apply failed".
        RETURN jsonb_build_object('ok', false, 'error', 'policy_apply_refused',
          'field', v_field, 'detail', v_upd);
      END IF;
      v_applied := v_applied || jsonb_build_object('policy', jsonb_build_object('field', v_field, 'value', v_val));
    END;
  END IF;

  -- 4b. CASCADE — epoch advance, and it MUST produce a sealed Materialization
  --     (P0-E, pgCK#28). The epoch is not a counter: the bump recompiles the
  --     plan surface (compile_plans + plan_cache_clear inside bump_epoch), and
  --     the rebuild is SEALED as a first-class ckp:Materialization that
  --     produces a ckp:Epoch carrying the surface digest. All in THIS txn: if
  --     the Materialization or Epoch fails its shape gate, the whole apply
  --     rolls back — a bumped epoch with no valid Materialization cannot
  --     commit. "Show me the Materialization that produced this epoch, and
  --     re-derive the surface at that epoch" is answerable from the seals.
  DECLARE
    -- this project's epoch, not a fixed kernel's: reading one kernel's epoch
    -- while bumping another's makes every other kernel restart from 1.
    -- 0.4.90 (§2): was COALESCE(...,1) while all six read sites use 0 — the two
    -- planes rendered the SAME absent row as different numbers. One convention now.
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
    v_comp_e int;
    v_srcd   text;
    v_surfd  text;
    v_kiri   text := format('urn:ckp:%s/kernel/ck', v_proj);
    v_eiri   text;
    v_miri   text;
  BEGIN
    -- bump THIS project's epoch. Hard-coded, it advanced one kernel's epoch on
    -- every apply by anyone, so every other kernel's epoch never moved and its
    -- plans were recompiled under a name it does not own.
    v_epoch := ckp.bump_epoch(v_proj);           -- recompiles plans + clears cache (same txn)
    v_comp_e := ckp._composed_shapes(v_proj);    -- rebuild the enforcement surface from the new shapes
    v_srcd  := ckp._surface_digest(pgrdf.add_graph(v_kiri));   -- the governed source shapes
    v_surfd := ckp._surface_digest(v_comp_e);                  -- the enforcement surface produced
    v_eiri  := format('urn:ckp:%s/epoch/%s', v_proj, v_epoch);
    v_miri  := format('urn:ckp:%s/materialization/%s', v_proj, v_epoch);
    -- the Epoch resource: the position, named by the digest of its surface.
    -- 0.4.67: TWO digest planes, each named for what it pins. surfaceDigest is
    -- the COPY plane — this store's bytes, what surface.check compares in-store
    -- and what the digest-match obligation consults; it moves on reload and is
    -- never cross-bench identity. structuralDigest is the plane that survives
    -- reload (first-degree bnode-signature algorithm, fleet-shared) — the one a
    -- third party CAN recompute from the published modules, and the one a
    -- cross-store verifier cites. Nobody minted early: this key ships in the
    -- same act as the code that derives it.
    PERFORM ckp.seal('epoch-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Epoch', '@id', v_eiri,
      C||'epoch', to_jsonb(v_epoch),
      C||'surfaceDigest', v_surfd,
      C||'structuralDigest', ckp._structural_digest(v_comp_e)));
    -- 0.4.97 (E-1): the live epoch row records the surface it ran under, from the
    -- SAME v_surfd that was just sealed into the Epoch. One computation, three
    -- writers — the table cannot drift from the seal, which is the whole failure
    -- D-1 was about one layer over.
    UPDATE ckp.kernel_epoch SET surface_digest = v_surfd WHERE kernel = v_proj;

    -- the Materialization: the sealed rebuild that produced that epoch.
    PERFORM ckp.seal('mat-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Materialization', '@id', v_miri,
      C||'materializes', v_kiri,
      C||'fromEpoch', to_jsonb(v_from),
      C||'toEpoch', to_jsonb(v_epoch),
      C||'sourceDigest', v_srcd,
      C||'surfaceDigest', v_surfd,
      C||'producesEpoch', v_eiri));
  END;

  -- 4c. QUERY AFFORDANCE (Tier 2 3/3b) — an add_affordance carrying query text is compiled into
  --     ckp.plans + registered plane='query', keyed to the new epoch (governed, sealed).
  IF v_op = 'add_affordance' AND (v_prop->'proposalDetail' ? 'query') THEN
    BEGIN
      PERFORM ckp.register_query_affordance(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('query_affordance', v_prop->'proposalDetail'->>'verb');
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'affordance_register_failed', 'detail', SQLERRM);
    END;
  END IF;

  -- 4d. PROOF OBLIGATION (0.4.65, §5b) — the seal-exit dual of 4c: where
  --     add_affordance opens a dispatch entry, add_proof_obligation closes the
  --     seal's exit with a check every future seal of the target type must
  --     satisfy. The registry row is the projected change (P0-E honoured);
  --     removal travels the same governed road with detail.active=false.
  IF v_op = 'add_proof_obligation' THEN
    BEGIN
      PERFORM ckp.register_proof_obligation(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('proof_obligation', v_prop->'proposalDetail'->>'obligation',
                                                   'obligation_active', COALESCE(v_prop->'proposalDetail'->>'active','true'));
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'obligation_register_failed', 'detail', SQLERRM);
    END;
  END IF;

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  -- 0.4.90 (L-6 / R5.3, CK.Lib.Js) — THE SUCCESS PATH CARRIES THE PAIR TOO.
  -- The REFUSAL path returned approvals AND quorum (see quorum_not_met above);
  -- the success path returned approvals alone, so a caller reading a successful
  -- apply could not tell 1-of-1 from 3-of-3 without a second read. The pair is
  -- the whole meaning: an approval count without the bar it cleared is not a
  -- number. `rehearsal` states the standing rule out loud rather than leaving
  -- the reader to infer it — quorum 1 means proposer, voter and applier may be
  -- the same identity, which is a rehearsal of governance, not consensus, and
  -- this substrate says so every time rather than once in a document.
  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'quorum', v_quorum,
                            'rehearsal', (v_quorum = 1),
                            'quorumNote', CASE WHEN v_quorum = 1
                              THEN 'quorum 1 — proposer, voter and applier may be one identity. This is REHEARSAL, not consensus.'
                              ELSE format('quorum %s cleared by %s DISTINCT non-anonymous identities', v_quorum, v_approvals) END,
                            'applied', v_applied,
                            'verified', ckp.verify(v_pid));
END;
$function$
;
