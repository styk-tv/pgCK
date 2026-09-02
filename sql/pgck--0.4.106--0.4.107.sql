-- pgck 0.4.106 -> 0.4.107
--
-- C-7 · an agent seal carries onBehalfOf; a direct human seal does NOT.
-- C-6 · in-kernel roles NARROW, and never widen the Tier-1 floor.
--
-- Both properties of one pathology, closed one act apart: the law was
-- complete and read by nothing. ckp:onBehalfOf (subPropertyOf
-- prov:actedOnBehalfOf, on InstanceShape) had no emitter; Role, Grant and
-- Membership had shapes, closed sets — and no reader.
--
-- C-7: the seal now derives onBehalfOf from ckp.on_behalf_of, set by the
-- trusted ingress BESIDE ckp.requester — from the verified connection, never
-- the payload; a body carrying its own claim has it STRIPPED (the fifth
-- server-derived stamp joins the #59 strip). Absence is the signal: a direct
-- seal carries nothing, and "on behalf of myself" is acting directly, so an
-- equal value is not stamped. One normaliser (urn_normalise) with createdBy.
--
-- C-6: ckp._role_permits(project, participant, action) — three clauses in
-- order: a project with NO sealed Memberships imposes nothing (0.4.81); the
-- declared OWNER is never narrowed by roles they set; everyone else needs a
-- Membership holding a Role whose Grant carries permAction = the act.
-- Consulted by propose (caller's target), vote and apply (the SEALED
-- proposal's target, never the applier's word). Refusal: role_required,
-- 42501, registered with its teaches. And Memberships are the OWNER'S to
-- seal — whoever binds roles binds themselves in, so ckp.seal refuses a
-- stranger's Membership into an owned project (42501, not_owner wording).
--
-- Controls: s87 (wired into smoke-s4); TDD C-7 and C-6 upgraded from
-- existence stubs to full behaviour probes — forged onBehalfOf claims strip,
-- per-action narrowing (a propose-only member cannot vote), the owner
-- exemption, the imposes-nothing floor, and the owner-settable gate.


CREATE OR REPLACE FUNCTION ckp._derived_stamps(p_subj text, p_type text, p_project text, p_participant text, p_shapes_graph integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_ep  int;
  v_shp text;
  v_giri text;
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF p_subj IS NULL OR p_type IS NULL THEN RETURN '{}'::jsonb; END IF;

  -- 0.4.79 -- M2 IS NOT OPTIONAL. producedBy names the kernel whose law governs
  -- this fact. With no kernel named this built 'urn:ckp:'||NULL||'/kernel/ck',
  -- and before clause 0 it built urn:ckp:demo/kernel/ck -- a jurisdiction that
  -- was never germinated. A fact governed by nobody is worse than a refused one.
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RAISE EXCEPTION 'ckp.seal: no kernel named, so this fact cannot carry M2 (producedBy) -- and a fact must say whose law governs it. The law IS loaded and readable: surface.declared, surface.typecheck and instance.validate all answer core-only. To seal, name your kernel: SELECT set_config(''ckp.project'', ''<your-kernel>'', true), or germinate one. (Until 0.4.79 this silently landed in the project ''demo'', whose kernel graph is empty.)';
  END IF;

  -- producedBy — the kernel that processed this instance. Server-derived.
  v_out := v_out || jsonb_build_object(N||'producedBy', 'urn:ckp:'||p_project||'/kernel/ck');

  -- createdBy — the resolved participant. Never from the payload; the caller's
  -- own claim was stripped before this ran.
  IF p_participant IS NOT NULL THEN
    v_out := v_out || jsonb_build_object(N||'createdBy', p_participant);
  END IF;

  -- 0.4.107 (C-7) — onBehalfOf, SERVER-DERIVED, ABSENCE IS THE SIGNAL. When an
  -- agent's verified connection acts for a participant, the trusted ingress
  -- sets ckp.on_behalf_of beside ckp.requester (exactly as it sets requester:
  -- from the verified connection, never the payload — a body carrying its own
  -- claim had it stripped before this ran). Present ⇒ an Agent sealed on that
  -- participant's behalf; absent ⇒ the participant acted directly. The two
  -- must stay distinguishable, so a value equal to the actor itself is NOT
  -- stamped — "on behalf of myself" is acting directly, and stamping it would
  -- erase the distinction the property exists to carry.
  DECLARE v_obo text := NULLIF(trim(COALESCE(current_setting('ckp.on_behalf_of', true), '')), '');
  BEGIN
    IF v_obo IS NOT NULL THEN
      -- urn_normalise, matching createdBy's own derivation two lines up — one
      -- normaliser for both identity stamps, or the same person diverges into
      -- two IRIs the moment their name carries an edge character.
      v_obo := 'urn:ckp:participant:'||ckp.urn_normalise(v_obo);
      IF v_obo IS DISTINCT FROM p_participant THEN
        v_out := v_out || jsonb_build_object(N||'onBehalfOf', v_obo);
      END IF;
    END IF;
  END;

  -- sealedAtEpoch — the producing kernel's epoch at seal. Carried as a JSON
  -- number so a re-projection of the stored body yields xsd:integer, which is
  -- what InstanceShape declares.
  SELECT epoch INTO v_ep FROM ckp.kernel_epoch WHERE kernel = p_project;
  v_out := v_out || jsonb_build_object(N||'sealedAtEpoch', to_jsonb(COALESCE(v_ep,0)));

  -- conformsToShape — the declared shape that targets this type, resolved from the
  -- same graph the gate validates against. Absent => omitted rather than invented.
  IF p_shapes_graph IS NOT NULL THEN
    SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_shapes_graph;
    SELECT j->>'s' INTO v_shp FROM pgrdf.sparql(format($q$
        PREFIX sh: <http://www.w3.org/ns/shacl#>
        SELECT ?s WHERE { GRAPH <%s> { ?s sh:targetClass <%s> } } LIMIT 1
      $q$, v_giri, p_type)) j;
    IF v_shp IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(N||'conformsToShape', v_shp);
    END IF;
  END IF;
  RETURN v_out;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._dispatch_safe(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  v_out := ckp.dispatch(p_verb, p_payload);
  RETURN v_out;
EXCEPTION
  WHEN OTHERS THEN
    -- The refusal is the RESULT. Carry the clause the gate named, plus SQLSTATE
    -- so a caller can tell a shape refusal from a transport fault, and keep the
    -- verb so a Trace-Id correlation still resolves. Never re-raise: re-raising
    -- is what killed the worker.
    --
    -- 0.4.71 — RESET THE ENGINE'S TERM CACHE after the aborted subtransaction.
    -- Any term FIRST-interned inside the abort is poisoned: it stores but SHACL
    -- cannot see it, so a caller's RETRY reusing the same fresh IRIs refuses
    -- with "MinCount not satisfied" on a field its body demonstrably carries.
    -- Measured three times on this wave (s56's flake class, s64's build, and
    -- pgck's own reconciliation seal taking three attempts); the suites carry
    -- per-file resets, but door callers had no protection until here — the
    -- catch block is the one place that KNOWS an abort just happened. Guarded:
    -- engines without the remedy skip silently, and a reset failure must never
    -- eat the refusal we owe the caller.
    BEGIN
      IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN
        PERFORM pgrdf.shmem_reset();
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN jsonb_build_object(
      'ok',      false,
      'refused', true,
      'verb',    p_verb,
      'sqlstate', SQLSTATE,
      'error',   SQLERRM
    );
END;
$function$;

COMMENT ON FUNCTION ckp._dispatch_safe(text, jsonb) IS
  'Transport-safe wrapper over ckp.dispatch. A gate refusal is returned as data '
  '({ok:false, refused:true, sqlstate, error}) instead of raising, because an '
  'unhandled RAISE inside the bgworker SPI call unwinds as a pgrx panic and '
  'terminates the worker — taking the auth-callout responder with it and closing '
  'the door for every client (measured 2026-08-11, pgck-bridge exit code 1).';

CREATE OR REPLACE FUNCTION ckp._role_permits(p_project text, p_participant text, p_action text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_piri text := 'urn:ckp:project:'||p_project;
  v_owner text;
BEGIN
  -- 0.4.107 (C-6) — TIER-2 ROLES, ENFORCED. Role/Grant/Membership have been
  -- declared law since the root shipped, read by NOTHING — the recurring
  -- pathology (declaration outruns projection), here at the authority layer.
  -- The rule, from TICK-ROSTER PASS-3 §5: in-kernel roles NARROW what a
  -- participant may do inside one kernel and never widen the Tier-1 floor.
  -- Three clauses, in order:
  --   * a project with NO sealed Memberships imposes nothing (the 0.4.81
  --     bind-only-what-declared-itself rule — same as ownership, same as the
  --     quorum floor);
  --   * the declared OWNER is never narrowed by roles — they set them, and a
  --     lock the keyholder can close on themselves is a foot-gun, not a floor;
  --   * everyone else needs a Membership in THIS project holding a Role whose
  --     Grant carries permAction = the act. Roles only ADD refusals: nothing
  --     here can grant what Tier-1 denied, because this function is consulted
  --     by verbs the caller could already reach.
  IF NOT EXISTS (SELECT 1 FROM ckp.instances i
                  WHERE i.body->>'type' = C||'Membership'
                    AND i.body->>(C||'memberOf') = v_piri) THEN
    RETURN true;
  END IF;
  SELECT i.body->>(C||'ownedBy') INTO v_owner FROM ckp.instances i
   WHERE i.body->>'@id' = v_piri AND i.body->>'type' = C||'Project'
   ORDER BY i.ts_created DESC LIMIT 1;
  IF v_owner IS NOT NULL AND v_owner = p_participant THEN
    RETURN true;
  END IF;
  RETURN EXISTS (
    SELECT 1
      FROM ckp.instances m
      JOIN ckp.instances r ON r.body->>'@id' = m.body->>(C||'holdsRole')
                          AND r.body->>'type' = C||'Role'
      JOIN LATERAL jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(r.body->(C||'grant')) = 'array'
                  THEN r.body->(C||'grant')
                  ELSE jsonb_build_array(r.body->(C||'grant')) END) g(iri) ON true
      JOIN ckp.instances gr ON gr.body->>'@id' = g.iri
                           AND gr.body->>'type' = C||'Grant'
     WHERE m.body->>'type' = C||'Membership'
       AND m.body->>(C||'memberOf') = v_piri
       AND m.body->>(C||'memberIs') = p_participant
       AND gr.body->>(C||'permAction') = p_action);
END;
$function$
;

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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
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
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'sqlstate', '42704', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'sqlstate', '55000', 'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 0.4.102 (C-2, SECOND HALF) — THE GATE MUST SIT ON THE PATH THE LIVE VERB
  -- TAKES. The 0.4.99 ownership check above parses the CALLER'S `about` for a
  -- urn:ckp:<proj>/ prefix — but a real apply's `about` is the Proposal @id
  -- (ckp://Proposal#…), which that regex never matches, so the live path was
  -- ungated: any party could apply a quorum-met proposal against an owned
  -- project by addressing the proposal, which is the only way anyone ever
  -- addresses one. Found by the TDD E-1 exercise — the FIRST full
  -- propose→vote→apply the ledger ever ran — not by C-2's probe, which asked
  -- the question in the one spelling the gate could hear. A check that cannot
  -- fail the thing it claims is not a check.
  --
  -- Re-derive the target project from the SEALED proposal's own `about` —
  -- written at propose from server state, never the applier's word — and ask
  -- the same question the pre-lookup gate asks, with the same rule: a declared
  -- owner binds, an undeclared one imposes nothing.
  DECLARE
    v_tgt_proj  text := substring(v_prop->>(C||'about') from '^urn:ckp:([a-z0-9-]+)/');
    v_tgt_owner text;
    v_applier   text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_tgt_proj IS NOT NULL THEN
      SELECT i.body->>(C||'ownedBy') INTO v_tgt_owner FROM ckp.instances i
       WHERE i.body->>'@id' = 'urn:ckp:project:'||v_tgt_proj
         AND i.body->>'type' = C||'Project'
       ORDER BY i.ts_created DESC LIMIT 1;
      IF v_tgt_owner IS NOT NULL THEN
        v_applier := CASE WHEN v_applier IS NULL THEN NULL
                          ELSE 'urn:ckp:participant:'||ckp._slug(v_applier) END;
        IF v_applier IS DISTINCT FROM v_tgt_owner THEN
          RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
            'error', 'not_owner',
            'about', v_prop->>(C||'about'), 'owner', v_tgt_owner,
            'hint', format('this proposal targets %s, which is owned by %s. Quorum answers '
                           'whether enough parties AGREED; it does not answer whether THIS '
                           'party may enact the change. Ask the owner to apply.',
                           v_prop->>(C||'about'), v_tgt_owner));
        END IF;
      END IF;
      -- 0.4.107 (C-6): role narrowing on the apply, same target derivation.
      -- Sits AFTER the ownership gate: an owner is never narrowed by the roles
      -- they set, and a non-owner who somehow reaches here (unowned project)
      -- still needs the apply grant where Memberships exist.
      IF NOT ckp._role_permits(v_tgt_proj,
              'urn:ckp:participant:'||ckp.urn_normalise(COALESCE(NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), ''), '')),
              'apply') THEN
        RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
          'error', 'role_required', 'action', 'apply', 'project', v_tgt_proj,
          'hint', 'this project seals Memberships, and yours (if any) holds no Role whose Grant carries permAction ''apply''.');
      END IF;
    END IF;
  END;
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
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'sqlstate', '55000', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  v_op := v_prop->>(C||'proposalOp');

  -- 4a. GRAPH APPLY (shape ops) — translate the op into the kernel graph (the §5.2 EFFECT).
  BEGIN
    v_ttl := ckp._op_to_ttl(v_prop);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_translate_failed', 'sqlstate', '22023', 'detail', SQLERRM);
  END;
  IF v_ttl IS NOT NULL THEN
    v_ga := ckp.apply_shape_ttl(v_ttl, v_proj);
    IF (v_ga->>'ok') IS DISTINCT FROM 'true' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'graph_apply_failed', 'sqlstate', '55000', 'detail', v_ga);
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
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'sqlstate', '22023',
          'hint', 'set_kernel_policy needs {field, value}');
      END IF;
      v_upd := ckp.update_typed(jsonb_build_object(
                 'id', v_kid,
                 'patch', jsonb_build_object(C||v_field, v_val)));
      IF (v_upd->>'ok') IS DISTINCT FROM 'true' THEN
        -- the refusal travels VERBATIM. A policy refused by the shape gate must
        -- say which clause refused it, not be flattened into "apply failed".
        RETURN jsonb_build_object('ok', false, 'error', 'policy_apply_refused', 'sqlstate', '55000',
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
      RETURN jsonb_build_object('ok', false, 'error', 'affordance_register_failed', 'sqlstate', '55000', 'detail', SQLERRM);
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
      RETURN jsonb_build_object('ok', false, 'error', 'obligation_register_failed', 'sqlstate', '55000', 'detail', SQLERRM);
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
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'sqlstate', '22023', 'op', v_op,
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
      RETURN jsonb_build_object('ok', false, 'error', 'detail_projects_nothing', 'sqlstate', '22023', 'op', v_op,
        'hint', 'add_proof_obligation needs detail.obligation + detail.targetType + detail.check (or detail.obligation + active:false to deactivate); without them apply bumps the epoch and registers nothing (P0-E)',
        'got', v_detail);
    END IF;
  END IF;
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_has_no_projector', 'sqlstate', '22023', 'op', v_op,
                              'hint', 'a governed op is refused at propose unless it can project a change (P0-E, pgCK#28)',
                              'allowed', to_jsonb(v_ops));
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
  END IF;
  BEGIN
    v_quorum := COALESCE((p_payload->>'requires_quorum')::int, 1);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'sqlstate', '22023',
                              'value', p_payload->>'requires_quorum');
  END;
  -- 0.4.98 (C-1 / L-8): a project that declared `shared` cannot then propose a
  -- change it may approve alone. The refusal names the clause and the cure, and
  -- points at the declaration rather than at a policy nobody can read.
  IF v_quorum < ckp._quorum_floor(p_kernel_urn) THEN
    RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '55000',
      'error', 'invalid_requires_quorum',
      'value', v_quorum,
      'floor', ckp._quorum_floor(p_kernel_urn),
      'hint', format('this project seals ckp:projectKind "shared", whose declared meaning is '
                     '"several members, where governed change clears a quorum". A quorum of %s '
                     'would let the proposer approve its own change. Propose at %s or higher, or '
                     'govern the project to "personal" first — that is a decision with a record, '
                     'which is the point.', v_quorum, ckp._quorum_floor(p_kernel_urn)));
  END IF;
  IF v_quorum < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_requires_quorum', 'sqlstate', '22023', 'value', v_quorum);
  END IF;
  -- 0.4.107 (C-6): a project that sealed Memberships narrows who may propose.
  DECLARE
    v_tgt text := substring(v_about from '^urn:ckp:([a-z0-9-]+)/');
    v_me  text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_tgt IS NOT NULL AND NOT ckp._role_permits(v_tgt, 'urn:ckp:participant:'||ckp.urn_normalise(COALESCE(v_me,'')), 'propose') THEN
      RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
        'error', 'role_required', 'action', 'propose', 'project', v_tgt,
        'hint', 'this project seals Memberships, and yours (if any) holds no Role whose Grant carries permAction ''propose''. Roles narrow: ask the owner for a Membership, or propose against a project that has not narrowed itself.');
    END IF;
  END;

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
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'sqlstate', '23514', 'violations', v_report->'violations');
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

CREATE OR REPLACE FUNCTION ckp.seal(p_instance_id text, p_body jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_core   INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_kgraph INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
  v_identity_key TEXT := COALESCE(
    NULLIF(current_setting('ckp.identity_key', true), ''),
    (SELECT v FROM ckp.config WHERE k='identity_key')
  );
  v_project TEXT := ckp._project();
  v_type   TEXT := p_body->>'type';
  v_missing TEXT;
  v_sha    TEXT;
  v_sig    TEXT;
  v_prev   BIGINT;
  v_now    TIMESTAMPTZ := now();
  v_led_ttl TEXT;
  v_prf_ttl TEXT;
  v_sub    TEXT;
  v_req    TEXT;
  v_display TEXT;
  v_email  TEXT;
  v_participant TEXT;
  N        TEXT := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_stamps JSONB := '{}'::jsonb;
  v_oblig  JSONB := '{}'::jsonb;
  v_ob     TEXT;
  v_res    TEXT;
  v_gref   TEXT;
BEGIN
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'ckp.seal: body has no "type"';
  END IF;
  IF v_identity_key IS NULL OR v_identity_key = '' THEN
    RAISE EXCEPTION 'ckp.seal: no identity key configured';
  END IF;

  -- 0. RESOLVE participant identity (CKF-3). Map an optional "participant"
  -- claims object {sub, preferred_username, email} to the canonical IRI
  -- urn:ckp:participant:<normalised-sub>; mint urn:ckp:participant:anon:<nonce>
  -- when absent or sub is empty. Display claims (preferred_username, email)
  -- are carried as non-authoritative attributes per NOTIFIES.pgCK §D.
  -- This MUST run before the body SHA (step 2) so the stored body, the ledger
  -- digest, and ckp.verify()'s recompute all hash the same canonical body.
  --
  -- IDENTITY HAS ONE SOURCE. `ckp.requester` is set transaction-locally by the
  -- relay from the callout-verified connection; the payload's participant.sub
  -- is whatever the client typed. Reading the payload here while germination
  -- read the GUC gave one seal two identities: a Project ownedBy a verified
  -- participant and createdBy anon:<nonce> -- "owned by someone, created by
  -- nobody" -- and it made createdBy client-assertable, which is the whole
  -- thing the four stamps exist to prevent. The verified connection WINS; a
  -- conflicting payload sub is ignored, not merged. The payload arm survives
  -- only for callers with no verified connection at all (direct SQL, tests).
  v_req     := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  v_sub     := p_body->'participant'->>'sub';
  v_display := NULLIF(trim(COALESCE(p_body->'participant'->>'preferred_username','')), '');
  v_email   := NULLIF(trim(COALESCE(p_body->'participant'->>'email','')), '');
  IF v_req IS NOT NULL THEN
    v_participant := 'urn:ckp:participant:' || ckp.urn_normalise(v_req);
  ELSIF p_body ? 'participant' AND v_sub IS NOT NULL AND length(trim(v_sub)) > 0 THEN
    v_participant := 'urn:ckp:participant:' || ckp.urn_normalise(v_sub);
  ELSE
    -- 0.4.64 — REFUSE, do not mint. This minted anon:<fresh-uuid> per call, so
    -- every unattributed write became a permanent fact belonging to nobody and
    -- N naked-path seals presented as N distinct participants (ck-dev's
    -- finding-1786732252462817000; quorum was closed at 0.4.62, and THIS closes
    -- unattributability itself). The door is unaffected: its anonymous tier is
    -- subscribe-only and never reaches seal; a verified connection always sets
    -- ckp.requester. Only the naked path (psql / pgRDF-side SPI) lands here,
    -- and the naked path must NAME an identity — a declared service identity
    -- is acceptable, an absent one is not. The 39 historical anon seals stand
    -- as fenced history; no new one can be created.
    RAISE EXCEPTION 'ckp.seal: unattributed write refused — no verified identity on this call. Name one explicitly: SELECT set_config(''ckp.requester'', ''<your declared identity, e.g. svc:smoke-suite>'', true) before sealing. The substrate no longer mints anon:<uuid> participants: a fact belonging to nobody is permanent, and fresh uuids let one caller impersonate many distinct parties.';
    v_display := NULL;
    v_email := NULL;
  END IF;
  -- Replace the raw claims object with the resolved canonical IRI; carry the
  -- display fields only when they were supplied alongside an identified sub.
  p_body := (p_body - 'participant')
    || jsonb_build_object(
      'https://conceptkernel.org/ontology/v3.11/core#participant', v_participant);
  IF v_display IS NOT NULL THEN
    p_body := jsonb_set(p_body, '{participant_display_name}', to_jsonb(v_display), true);
  END IF;
  IF v_email IS NOT NULL THEN
    p_body := jsonb_set(p_body, '{participant_email}', to_jsonb(v_email), true);
  END IF;

  -- 0b. #59: STRIP any caller-asserted substrate stamp. All four are maxCount 1
  -- in ckp:InstanceShape, so a body carrying its own createdBy was projected
  -- alongside the derived one and refused on MaxCountConstraintComponent — a
  -- denial any client could trigger, reading as a shape defect rather than as a
  -- rejected claim. §4.3 says these are server-derived and claim-ignoring;
  -- removing them here is what makes that structural instead of conventional.
  p_body := p_body - ARRAY[
    N||'producedBy', N||'createdBy', N||'sealedAtEpoch', N||'conformsToShape',
    -- 0.4.107 (C-7): onBehalfOf joins the strip — it is the FIFTH server-derived
    -- stamp, and a client that could assert it would forge the agent/direct
    -- distinction the property exists to carry. Absence is the signal, so a
    -- stripped claim leaves exactly the honest state: acted directly.
    N||'onBehalfOf'
  ];

  -- 0.4.107 (C-6) — MEMBERSHIPS ARE OWNER-SETTABLE. A Membership is the
  -- binding that makes a Role bite (Role and Grant instances bind nothing by
  -- themselves), so whoever can seal one legislates who may act in the
  -- project. That is the owner's pen: where the target project declares an
  -- owner, only the owner writes Memberships — the E-4 rule at the authority
  -- layer. An unowned project imposes nothing, as everywhere else.
  IF p_body->>'type' = N||'Membership' THEN
    DECLARE
      v_mo    text := p_body->>(N||'memberOf');
      v_mown  text;
    BEGIN
      IF v_mo IS NOT NULL THEN
        SELECT i.body->>(N||'ownedBy') INTO v_mown FROM ckp.instances i
         WHERE i.body->>'@id' = v_mo AND i.body->>'type' = N||'Project'
         ORDER BY i.ts_created DESC LIMIT 1;
        IF v_mown IS NOT NULL AND v_mown IS DISTINCT FROM v_participant THEN
          RAISE EXCEPTION USING ERRCODE = '42501',
            MESSAGE = format('ckp.seal: not_owner — a Membership in %s is the owner''s to seal (owner: %s). Roles narrow a project on its owner''s declaration; a stranger who could bind roles could bind themselves in.', v_mo, v_mown);
        END IF;
      END IF;
    END;
  END IF;

  -- 1. VALIDATE the payload against the COMPOSED shapes graph (P0-B, pgCK#25).
  --
  -- Was: a hand-rolled SPARQL scan for sh:minCount against the KERNEL graph only.
  -- That saw no core shape (the kernel graph holds only the kernel's own), and it
  -- read past every other SHACL component the engine enforces. Measured on the
  -- bench, same malformed body, two shapes graphs: kernel -> conforms TRUE,
  -- composed -> conforms FALSE. Twelve Core components are measured enforcing.
  --
  -- Now: project the body to RDF, stamp the declared type's ancestors so
  -- InstanceShape and friends target it (pgrdf.validate does NOT entail, and
  -- entailment is per-graph — either gap silently returns conforms=true), and
  -- validate against core UNION kernel.
  DECLARE
    v_comp    int;
    v_cand    text;
    v_report  jsonb;
    v_excl    text := NULL;
  BEGIN
    -- 0.4.73 — deadlock escape, derived never claimed: when the candidate IS a
    -- core#Supersession, the graph named by its target Adoption's adopts value
    -- is excluded from the fail-closed composition — the cure must not be
    -- gated by the poison it removes. Derived from the SEALED target, so a
    -- caller cannot exclude arbitrary graphs by asserting supersedes at random:
    -- a supersedes that names no sealed Adoption excludes nothing.
    IF v_type = 'https://conceptkernel.org/ontology/v3.11/core#Supersession' THEN
      SELECT a.body->>'https://conceptkernel.org/ontology/v3.11/core#adopts' INTO v_excl
        FROM ckp.instances a
       WHERE a.body->>'@id' = p_body->>'https://conceptkernel.org/ontology/v3.11/core#supersedes'
         AND a.body->>'type' = 'https://conceptkernel.org/ontology/v3.11/core#Adoption';
    END IF;
    v_comp := ckp._composed_shapes(v_project, v_excl);
    -- P0-D mechanism 2 (pgCK#27): fail closed on the UNDECLARED TYPE, BEFORE
    -- validation runs. This is the half that produced the live defect — an
    -- invented type URN is targeted by no shape, so SHACL never runs and the
    -- body seals verified:true. The lookup refuses it; a declared type (class
    -- or shape target) passes on to the measured-enforcing gate below.
    IF NOT ckp._type_admitted(v_type, v_project, v_comp) THEN
      RAISE EXCEPTION 'ckp.seal: type % is not admitted — no shape targets it and it is declared by no class in the composed surface (undeclared types cannot seal; SHACL would validate them vacuously)', COALESCE(v_type, '<null>');
    END IF;
    -- pgCK#41: the four substrate-derived properties (producedBy, createdBy,
    -- sealedAtEpoch, conformsToShape) are demanded by ckp:InstanceShape with
    -- minCount 1, but were derived AFTER this gate — so on the v3.11 root every
    -- Instance-classed seal failed by construction. Derive them INTO the
    -- candidate the gate validates: what is checked is what will be stamped.
    --
    -- #59: derive ONCE, here, and keep the jsonb. The Turtle below and the
    -- stored body in step 2 are two renderings of this single value, so the
    -- gate and the store cannot disagree about what was stamped.
    v_stamps := ckp._derived_stamps(p_instance_id, v_type, v_project, v_participant, v_comp);
    v_cand := ckp._body_to_ttl(p_body, p_instance_id, v_comp)
              || ckp._parent_closure_ttl(v_type, p_instance_id, v_comp)
              || ckp._stamps_to_ttl(p_instance_id, v_stamps);
    v_report := ckp.validate_report(v_cand, v_comp);
    -- 0.4.72 — THE GATE LEARNS SEVERITY (guidance-as-validation, vision §2.0).
    -- Results at sh:Violation — or with no severity, SHACL's default — REFUSE
    -- exactly as before: every pre-existing shape carries no explicit severity,
    -- so nothing weakens (the negative control). Results a shape deliberately
    -- authored at sh:Warning/sh:Info SEAL AND SURFACE: they ride a txn-local
    -- GUC to the reply's `warnings`, so guidance reaches the caller at zero
    -- marginal cost — the validation already ran. "Valid core looks like this;
    -- you get warnings" — and the no-warnings obligation (§2.0a) is the
    -- governed ratchet that turns them into refusals for kernels that adopt it.
    PERFORM set_config('ckp.last_warnings', '', true);
    DECLARE
      v_viol jsonb; v_warn jsonb;
    BEGIN
      SELECT COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IS DISTINCT FROM 'sh:Warning'
                                             AND r->>'resultSeverity' IS DISTINCT FROM 'sh:Info'), '[]'::jsonb),
             COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IN ('sh:Warning','sh:Info')), '[]'::jsonb)
        INTO v_viol, v_warn
        FROM jsonb_array_elements(COALESCE(v_report->'violations', '[]'::jsonb)) r;
      IF jsonb_array_length(v_viol) > 0 THEN
        RAISE EXCEPTION 'ckp.seal: payload fails the composed shape gate: %',
          COALESCE(ckp._report_summary(jsonb_build_object('conforms','false','violations',v_viol)), v_viol::text);
      END IF;
      IF jsonb_array_length(v_warn) > 0 THEN
        PERFORM set_config('ckp.last_warnings', v_warn::text, true);
      END IF;
    END;
  END;

  -- 1b. PROOF OBLIGATIONS (0.4.65, §5b) — the seal's exit, extensible by
  -- agreement. The shape gate above judges FORM; obligations judge whatever the
  -- registered check judges (the debut, digest-match, judges REFERENCE: a cited
  -- surfaceDigest must be one an Epoch sealed). Every ACTIVE obligation this
  -- kernel registered for this exact type runs; one refusal refuses the seal.
  -- Satisfactions become proof rows at step 4b — the agreement leaves a mark on
  -- every fact it guarded, so "which checks did this seal pass" is a read.
  v_oblig := ckp._run_proof_obligations(p_instance_id, v_type, p_body, v_project);
  IF v_oblig ? 'refused' THEN
    RAISE EXCEPTION 'ckp.seal: proof obligation % refused this candidate — %',
      v_oblig->>'refused', v_oblig->>'reason';
  END IF;

  -- 2. MATERIALIZE durable instance.
  --
  -- #59: the stamps join the body BEFORE the digest. Merged last so they win
  -- over anything of the same name (nothing can, after 0b) and so v_sha — and
  -- therefore the HMAC, the ledger, the proof and ckp.verify()'s recompute —
  -- covers the provenance. Before this the attestation said "this body was
  -- sealed"; it now says "by this participant, under this shape, at this epoch".
  p_body := p_body || v_stamps;
  v_sha := encode(digest(convert_to(p_body::text,'UTF8'),'sha256'),'hex');
  v_sig := encode(hmac(v_sha, v_identity_key, 'sha256'),'hex');
  SELECT max(seq) INTO v_prev FROM ckp.ledger;
  INSERT INTO ckp.instances(id, body) VALUES (p_instance_id, p_body)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, ts_updated = v_now;

  -- 3. VALIDATE the protocol's OWN ledger op, then write it.
  v_led_ttl := format($t$
    @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:led:%s> a ckp:LedgerEntry ;
      ckp:about <%s> ; ckp:bodySha "%s" ; ckp:sig "%s" ;
      ckp:prev %s ;
      ckp:ts "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, v_sig,
    -- v3.11 LedgerEntryShape demands ckp:prev (minCount 1, xsd:integer) — the
    -- chain position, which v3.8 left implicit in the relational prev_seq.
    -- Genesis encodes as 0: the column stays NULL (no referent), the protocol
    -- statement is "nothing precedes me", and a bare Turtle integer is
    -- xsd:integer, matching the declared datatype.
    COALESCE(v_prev, 0)::text, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_led_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: ledger entry fails ckp:LedgerEntryShape (core governance)';
  END IF;
  INSERT INTO ckp.ledger(instance_id, body_sha256, sig, prev_seq)
  VALUES (p_instance_id, v_sha, v_sig, v_prev);

  -- 4. VALIDATE the protocol's OWN proof op, then write it.
  v_prf_ttl := format($t$
    @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:prf:%s> a ckp:Proof ;
      ckp:about <%s> ; ckp:method "hmac+sha256" ; ckp:digest "%s" ;
      ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_prf_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: proof fails ckp:ProofShape (core governance)';
  END IF;
  INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id,'hmac+sha256',v_sha);

  -- 4b. APPEND one proof per SATISFIED obligation (0.4.65, §5b) — same digest,
  -- method naming the agreement ('obligation:<name>'). ckp.proof's absent
  -- uniqueness is the placed joint this stands on: the hmac row proves the
  -- bytes, each obligation row proves one agreed check held when they sealed.
  -- Validated against ckp:ProofShape like the hmac row — the protocol's own
  -- ops pass their own gate or nothing does.
  FOR v_ob IN SELECT jsonb_array_elements_text(COALESCE(v_oblig->'satisfied','[]'::jsonb))
  LOOP
    v_prf_ttl := format($t$
      @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
      @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
      <urn:ckp:prf:%s:%s> a ckp:Proof ;
        ckp:about <%s> ; ckp:method "obligation:%s" ; ckp:digest "%s" ;
        ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
      p_instance_id, v_ob, p_instance_id, v_ob, v_sha, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
    IF NOT ckp.validate(v_prf_ttl, v_core) THEN
      RAISE EXCEPTION 'ckp.seal: obligation proof % fails ckp:ProofShape (core governance)', v_ob;
    END IF;
    INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id, 'obligation:'||v_ob, v_sha);
  END LOOP;

  -- 4c. IDENTITY EVIDENCE (0.4.70) — the sealed half of the fleet identity
  -- contract (pgRDF operation-1786906298085342000, confirmed by pgck in
  -- operation-1786897156122855000). Two GUCs, relay-set on the channel clients
  -- cannot write, land as proof rows so verified-at-time becomes SEALABLE
  -- EVIDENCE riding the ledger into every future epoch, instead of the
  -- substrate's unrecorded word. The attach list is CLOSED at these two:
  -- anything beyond them is argued for on the wire, never slipped in.
  --
  --   token-residue   digest = the claims fingerprint itself (iss/kid/sub/exp
  --                   hash, 64-hex). NEVER the token: a raw JWT (eyJ…) fails
  --                   the pattern and REFUSES the seal — the never-the-token
  --                   rule is structural, not conventional. Absent GUC = no
  --                   row = honestly unattested (tests, raw plane).
  --   grant-ref       the acting voted Grant's URN rides in the METHOD
  --                   ('grant-ref:<urn>'), readable for resolve-never-believe
  --                   custody (pgRDF#122); digest = v_sha, consistent with
  --                   obligation rows (evidence about THIS sealed body).
  v_res := NULLIF(trim(COALESCE(current_setting('ckp.token_residue', true), '')), '');
  IF v_res IS NOT NULL THEN
    IF v_res !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'ckp.seal: ckp.token_residue must be a 64-hex claims fingerprint (sha256 over iss/kid/sub/exp), NEVER the token itself — bearer tokens replay, and a raw credential in the evidence plane is permanent. Got a value of length %.', length(v_res);
    END IF;
    v_prf_ttl := format($t$
      @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
      @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
      <urn:ckp:prf:%s:tr> a ckp:Proof ;
        ckp:about <%s> ; ckp:method "token-residue" ; ckp:digest "%s" ;
        ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
      p_instance_id, p_instance_id, v_res, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
    IF NOT ckp.validate(v_prf_ttl, v_core) THEN
      RAISE EXCEPTION 'ckp.seal: token-residue proof fails ckp:ProofShape (core governance)';
    END IF;
    INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id, 'token-residue', v_res);
  END IF;
  v_gref := NULLIF(trim(COALESCE(current_setting('ckp.grant_ref', true), '')), '');
  IF v_gref IS NOT NULL THEN
    IF v_gref !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
      RAISE EXCEPTION 'ckp.seal: ckp.grant_ref must be the acting Grant''s URN/IRI, got %', v_gref;
    END IF;
    -- the URN character gate above makes this string build injection-safe.
    v_prf_ttl := format($t$
      @prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
      @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
      <urn:ckp:prf:%s:gr> a ckp:Proof ;
        ckp:about <%s> ; ckp:method "grant-ref:%s" ; ckp:digest "%s" ;
        ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
      p_instance_id, p_instance_id, v_gref, v_sha, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
    IF NOT ckp.validate(v_prf_ttl, v_core) THEN
      RAISE EXCEPTION 'ckp.seal: grant-ref proof fails ckp:ProofShape (core governance)';
    END IF;
    INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id, 'grant-ref:'||v_gref, v_sha);
  END IF;

  -- 5. PROJECT link triples for Task/Goal instances into the project board graph (CKB-5).
  PERFORM ckp.project_links(v_project, p_instance_id, p_body);

  -- 6. PROJECT THE SPINE (0.4.59, pgRDF §4.4): the sealed body — stamps included,
  -- since they merged at step 2 — becomes quads in <project>/instances, so the
  -- fence census and every oracle signal are SPARQL, adoptable by any kernel.
  PERFORM ckp._project_instance_spine(p_instance_id, p_body, v_project);

  RETURN v_sha;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.vote(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_core      int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_about     text := p_payload->>'about';   -- the Proposal @id (IRI)
  -- VoteShape declares ckp:voteValue; this read only 'value', so a caller using
  -- the declared name got invalid_vote_value. Accept both.
  v_value     text := COALESCE(p_payload->>'value', p_payload->>'voteValue');
  v_prop      jsonb;
  v_quorum    int;
  v_approvals int;
  v_vid       text;
  v_body      jsonb;
  v_ttl       text;
  v_report    jsonb;
BEGIN
  -- 1. injection-safe field gate (mirrors VoteShape).
  IF v_value IS NULL OR v_value NOT IN ('approve','reject') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_vote_value', 'sqlstate', '22023', 'value', v_value);
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'sqlstate', '22023', 'about', v_about);
  END IF;

  -- 2. the Proposal must exist and still be pending.
  SELECT body INTO v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'sqlstate', '42704', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'sqlstate', '55000',
                              'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 0.4.107 (C-6): role narrowing on the vote, derived from the SEALED
  -- proposal's target project (never the caller's word) — same derivation as
  -- apply's ownership gate.
  DECLARE
    v_tgt text := substring(v_prop->>(C||'about') from '^urn:ckp:([a-z0-9-]+)/');
    v_me  text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
  BEGIN
    IF v_tgt IS NOT NULL AND NOT ckp._role_permits(v_tgt, 'urn:ckp:participant:'||ckp.urn_normalise(COALESCE(v_me,'')), 'vote') THEN
      RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
        'error', 'role_required', 'action', 'vote', 'project', v_tgt,
        'hint', 'this project seals Memberships, and yours (if any) holds no Role whose Grant carries permAction ''vote''.');
    END IF;
  END;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);

  v_vid := 'vote-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 3. authoritative SHACL gate (VoteShape) — values field-validated, so the TTL is safe.
  v_ttl := '@prefix ckp: <'||C||'> .'||chr(10)||
           '<ckp://Vote#'||v_vid||'> a ckp:Vote ; ckp:about <'||v_about||'> ; '||
           'ckp:voteValue "'||v_value||'" .';
  v_report := ckp.validate_report(v_ttl, v_core);
  IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'sqlstate', '23514', 'violations', v_report->'violations');
  END IF;

  -- 4. seal the Vote (sealed by the session identity — a human approval is indistinguishable).
  v_body := jsonb_build_object(
    'type',         C||'Vote',
    '@id',          'ckp://Vote#'||v_vid,
    C||'about',     v_about,
    C||'voteValue', v_value
  );
  PERFORM ckp.seal(v_vid, v_body);

  -- 5. quorum: DISTINCT accountable parties (0.4.62) — see ckp.apply for the
  -- mechanism and ck-dev's finding. Votes are not approvals; parties are.
  SELECT count(DISTINCT body->>(C||'createdBy')) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote'
      AND body->>(C||'about') = v_about
      AND body->>(C||'voteValue') = 'approve'
      AND COALESCE(body->>(C||'createdBy'),'') NOT LIKE 'urn:ckp:participant:anon:%';

  RETURN jsonb_build_object('ok', true, 'vote', v_vid, 'proposal', v_about, 'value', v_value,
                            'approvals', v_approvals, 'quorum', v_quorum,
                            'quorum_met', v_approvals >= v_quorum, 'verified', ckp.verify(v_vid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._role_permits(p_project text, p_participant text, p_action text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_piri text := 'urn:ckp:project:'||p_project;
  v_owner text;
BEGIN
  -- 0.4.107 (C-6) — TIER-2 ROLES, ENFORCED. Role/Grant/Membership have been
  -- declared law since the root shipped, read by NOTHING — the recurring
  -- pathology (declaration outruns projection), here at the authority layer.
  -- The rule, from TICK-ROSTER PASS-3 §5: in-kernel roles NARROW what a
  -- participant may do inside one kernel and never widen the Tier-1 floor.
  -- Three clauses, in order:
  --   * a project with NO sealed Memberships imposes nothing (the 0.4.81
  --     bind-only-what-declared-itself rule — same as ownership, same as the
  --     quorum floor);
  --   * the declared OWNER is never narrowed by roles — they set them, and a
  --     lock the keyholder can close on themselves is a foot-gun, not a floor;
  --   * everyone else needs a Membership in THIS project holding a Role whose
  --     Grant carries permAction = the act. Roles only ADD refusals: nothing
  --     here can grant what Tier-1 denied, because this function is consulted
  --     by verbs the caller could already reach.
  IF NOT EXISTS (SELECT 1 FROM ckp.instances i
                  WHERE i.body->>'type' = C||'Membership'
                    AND i.body->>(C||'memberOf') = v_piri) THEN
    RETURN true;
  END IF;
  SELECT i.body->>(C||'ownedBy') INTO v_owner FROM ckp.instances i
   WHERE i.body->>'@id' = v_piri AND i.body->>'type' = C||'Project'
   ORDER BY i.ts_created DESC LIMIT 1;
  IF v_owner IS NOT NULL AND v_owner = p_participant THEN
    RETURN true;
  END IF;
  RETURN EXISTS (
    SELECT 1
      FROM ckp.instances m
      JOIN ckp.instances r ON r.body->>'@id' = m.body->>(C||'holdsRole')
                          AND r.body->>'type' = C||'Role'
      JOIN LATERAL jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(r.body->(C||'grant')) = 'array'
                  THEN r.body->(C||'grant')
                  ELSE jsonb_build_array(r.body->(C||'grant')) END) g(iri) ON true
      JOIN ckp.instances gr ON gr.body->>'@id' = g.iri
                           AND gr.body->>'type' = C||'Grant'
     WHERE m.body->>'type' = C||'Membership'
       AND m.body->>(C||'memberOf') = v_piri
       AND m.body->>(C||'memberIs') = p_participant
       AND gr.body->>(C||'permAction') = p_action);
END;
$function$
;


INSERT INTO ckp.refusal_registry (code, sqlstate, teaches) VALUES
  ('role_required',              '42501', 'this project seals Memberships (Tier-2 roles) and the acting participant holds no Role whose Grant carries the needed permAction; roles NARROW — a project with no Memberships imposes nothing, and the owner is never narrowed by roles they set')
ON CONFLICT (code) DO UPDATE SET sqlstate = EXCLUDED.sqlstate, teaches = EXCLUDED.teaches;
