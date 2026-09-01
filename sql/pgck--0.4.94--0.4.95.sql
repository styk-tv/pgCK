-- pgck 0.4.94 -> 0.4.95
--
-- C-4 — set_kernel_policy: the route the law already mandated and did not have.
--
-- core declares seven Kernel policy properties (weightAssent, weightDissent,
-- weightImplicit, decayLambda, thresholdDefer, thresholdPromote,
-- thresholdDiscard) and says of each that it is "an OVERRIDE, sealed only
-- through propose->vote->apply". No projector could write a Kernel property, so
-- the mandated route did not exist and all seven were unreachable. Measured: zero
-- kernels on any door carry any of them.
--
-- THIS PROJECTOR CHECKS NO RANGES, AND THAT IS THE DESIGN.
-- Measured on the composed surface BEFORE writing it, with the required
-- properties present so the bounds were isolated:
--     in-range set                     conforms = true
--     weightDissent  +0.5              conforms = FALSE
--     weightImplicit  1.5              conforms = FALSE
--     decayLambda    -0.1              conforms = FALSE
--     thresholdDiscard >= Promote      conforms = FALSE   <- cross-property
-- The law enforces all seven, including the one no per-property constraint can
-- catch. A projector carrying its own copy of the bounds would be a second
-- implementation of a rule that already exists — the defect D-1 corrected one
-- layer over. You do not enforce your own shape; you declare it, and the ground
-- refuses what violates it.
--
-- The route: no shape projection (_op_to_ttl returns NULL, graph untouched),
-- because apply_shape_ttl's META-FENCE admits only rdf/rdfs/owl/sh plus three
-- transition predicates — a core#weightAssent triple is fence_violation by
-- design, and widening that fence to admit policy would let any shape op smuggle
-- instance data into the kernel graph. Instead the policy is applied as a
-- governed patch to the SEALED Kernel through ckp.update_typed, which is
-- composed-aware: an undeclared field is refused BY NAME rather than minted, and
-- ckp.seal runs the gate that enforces the bounds. Both halves come for free.
--
-- A refusal from the gate travels VERBATIM as policy_apply_refused with the
-- field named — flattening it into "apply failed" would lose the clause, which is
-- the whole value of a refusal.

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
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);
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

CREATE OR REPLACE FUNCTION ckp.propose_change(p_kernel_urn text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_core   int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  -- P0-E (pgCK#28): NO GOVERNED OP WITHOUT A PROJECTOR. An op that cannot
  -- project a change is refused HERE, at propose — never sealed as an inert
  -- "applied" that bumps the epoch and changes nothing. These four have a
  -- projector today: add_class / add_property / set_transition_map translate
  -- via ckp._op_to_ttl; add_affordance registers a query/derived plan at apply.
  -- modify_shape_constraint / set_quorum / set_materialize_policy have none yet
  -- (they would seal and do nothing) — refused until a projector exists,
  -- default-deny per I2. Widening this set requires implementing the projector,
  -- not editing the list. 0.4.65 adds add_proof_obligation (§5b): its projector
  -- is ckp.register_proof_obligation at apply — the obligation registry is the
  -- change it projects, the seal-exit dual of add_affordance's dispatch entry.
  -- 0.4.95 (C-4) — set_kernel_policy joins the closed op set. The law declares
  -- seven Kernel policy properties (weights, decay, thresholds) and states that
  -- each is "an OVERRIDE, sealed only through propose->vote->apply". No projector
  -- could write a Kernel property, so the route the law mandates did not exist and
  -- all seven were unreachable. This is that route.
  v_ops    text[] := ARRAY['add_class','add_property','set_transition_map','add_affordance','add_proof_obligation','set_kernel_policy'];
  v_op     text := p_payload->>'op';
  -- ckp.dispatch calls this with v_proj -- the bare project SEGMENT ('pgck'),
  -- not a URN, despite the parameter name. Defaulting `about` to it produced a
  -- literal where ProposalShape demands sh:IRI, so EVERY proposal that omitted
  -- `about` was refused. Build the kernel IRI when a bare segment arrives.
  v_about  text := COALESCE(p_payload->>'about',
                            CASE WHEN position(':' in p_kernel_urn) > 0 THEN p_kernel_urn
                                 ELSE 'urn:ckp:'||p_kernel_urn||'/kernel/ck' END);
  v_detail jsonb;
  v_quorum int;
  v_pid    text;
  v_body   jsonb;
  v_ttl    text;
  v_report jsonb;
BEGIN
  -- 1. INJECTION-SAFE FIELD GATE (mirrors ProposalShape; makes step 2's TTL construction safe).
  -- P0-E, SECOND HALF. That the OP has a projector is not enough: the DETAIL must
  -- carry something to project. add_affordance with an empty detail sealed as
  -- `applied`, bumped the epoch, registered nothing, and returned ok:true with
  -- graph_changed:false and no error anywhere -- measured on pgck, epoch 5 is
  -- exactly that inert applied. Refuse at propose, which is what P0-E promised.
  IF v_op = 'add_affordance' THEN
    v_detail := COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb);
    IF NOT (v_detail ? 'verb') OR NOT (v_detail ? 'query') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'op', v_op,
        'hint', 'add_affordance needs detail.verb and detail.query; without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  -- add_proof_obligation, same P0-E half: an activation must name the obligation,
  -- its target type AND a check from the fixed registry; a deactivation
  -- ({active:false}) needs only the obligation name. The strict parse (IRI
  -- shape, check-in-registry) lives in ckp.register_proof_obligation — refused
  -- again at apply if it fails there; this gate refuses the detail that could
  -- not project anything at all.
  IF v_op = 'add_proof_obligation' THEN
    v_detail := COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb);
    IF NOT (v_detail ? 'obligation')
       OR (COALESCE(v_detail->>'active','true') <> 'false'
           AND (NOT (v_detail ? 'targetType') OR NOT (v_detail ? 'check'))) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'op', v_op,
        'hint', 'add_proof_obligation needs detail.obligation + detail.targetType + detail.check (or detail.obligation + active:false to deactivate); without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_has_no_projector', 'op', v_op,
                              'hint', 'a governed op is refused at propose unless it can project a change (P0-E, pgCK#28)',
                              'allowed', to_jsonb(v_ops));
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  BEGIN
    v_quorum := COALESCE((p_payload->>'requires_quorum')::int, 1);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum',
                              'value', p_payload->>'requires_quorum');
  END;
  IF v_quorum < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'value', v_quorum);
  END IF;

  v_pid := 'proposal-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 2. AUTHORITATIVE SHACL GATE — validate against ProposalShape (core graph). Values are
  --    field-validated above, so this string build cannot inject a triple.
  v_ttl := '@prefix ckp: <'||C||'> .'||chr(10)||
           '@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .'||chr(10)||
           '<ckp://Proposal#'||v_pid||'> a ckp:Proposal ; ckp:about <'||v_about||'> ; '||
           'ckp:proposalState "pending" ; ckp:requiresQuorum "'||v_quorum::text||'"^^xsd:integer ; '||
           'ckp:proposalOp "'||v_op||'" .';
  v_report := ckp.validate_report(v_ttl, v_core);
  IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'violations', v_report->'violations');
  END IF;

  -- 3. SEAL the Proposal{pending} — DATA about the type, not yet the type. ckp.seal writes the
  --    instance + ledger + proof HMAC chain.
  v_body := jsonb_build_object(
    'type',              C||'Proposal',
    '@id',               'ckp://Proposal#'||v_pid,
    C||'about',          v_about,
    C||'proposalState',  'pending',
    C||'proposalOp',     v_op,
    C||'requiresQuorum', v_quorum::text,
    -- accept BOTH spellings: the door historically took 'detail' while the
    -- sealed key is 'proposalDetail', so a caller using the name it reads back
    -- silently got {}.
    'proposalDetail',    COALESCE(p_payload->'detail', p_payload->'proposalDetail', '{}'::jsonb)
  );
  PERFORM ckp.seal(v_pid, v_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_pid, 'proposal_iri', 'ckp://Proposal#'||v_pid,
                            'state', 'pending', 'op', v_op, 'verified', ckp.verify(v_pid));
END;
$function$
;
