-- pgck 0.4.101 -> 0.4.102
--
-- E-4 · ownership cannot be taken by a non-owner — and now it cannot.
-- E-5 · one id vocabulary across the verbs — read and write alike.
-- C-2 · second half: the apply ownership gate moves onto the path real
--       applies actually take.
--
-- Found while answering whether a kernel can be handed to another party. It
-- cannot — and worse, it could be TAKEN: ckp:ownedBy was an ordinary declared
-- property of ckp:Project, so instance.update patched it like any other key.
-- Both guards that read it — the germinate guard (0.4.89) and the apply gate
-- (0.4.99) — were therefore bypassable in one step: re-own the Project, then
-- re-germinate or apply freely. Measured on a virgin 0.4.101 install: a
-- non-owner moved a Project from tdd-e4-owner to tdd-e4-attacker through a
-- plain instance.update. Germination's own comment calls ownedBy "the triple a
-- client cannot write". From this version, that comment is true.
--
-- ckp.update_typed:
--   * ckp:ownedBy is not patchable by ANYONE — server-derived at germination,
--     and no transfer verb exists. Its absence is the filed finding; the
--     lawful hand-over is a governed verb, not a patch. Refusal:
--     ownership_not_patchable, sqlstate 42501, naming both gates a patchable
--     owner would void.
--   * ckp:projectKind is patchable only by the DECLARED owner — it is the
--     quorum floor (C-1/L-8): a stranger flipping a shared project to personal
--     drops the floor to 1 and self-approves, the same takeover one link over.
--     An unowned instance imposes nothing (the 0.4.81 rule). Refusal:
--     not_owner, byte-compatible with apply's gate.
--   * Both guards sit AFTER key resolution, so every spelling — bare, CURIE,
--     full IRI — meets them (the E-3 lesson).
--   * E-5: the verb now resolves ids through the SAME ckp._resolve_id
--     instance.get uses — bare, ckp://Type#id and urn:ckp:instance:<id> all
--     patch, and an unknown id's refusal names the accepted forms instead of
--     pointing at existence when the defect was spelling.
--
-- ckp.apply:
--   * The 0.4.99 ownership gate parsed the CALLER'S `about` for a
--     urn:ckp:<proj>/ prefix — but a real apply's `about` is the Proposal @id
--     (ckp://Proposal#…), which that regex never matches, so the live path was
--     ungated: any party could apply a quorum-met proposal against an owned
--     project by addressing the proposal, which is the only way anyone ever
--     addresses one. Found by the TDD E-1 exercise, the first full
--     propose→vote→apply the ledger ever ran — not by C-2's probe, which asked
--     in the one spelling the gate could hear. The gate now re-derives the
--     target project from the SEALED proposal's own `about` (written at
--     propose, never the applier's word) and asks the same question there.
--     Same rule both halves: a declared owner binds, an undeclared one
--     imposes nothing.
--
-- Negative controls: sql/test/s82_ownership_patch_guard.sql (wired into
-- smoke-s4) — non-owner refused BY NAME, owner ALSO refused on ownedBy (the
-- rule is server-derived, not owner-gated), an unrelated patch still lands (a
-- gate, not a wall), projectKind owner-gated both ways, @id-form patch lands
-- identically to bare, unknown id names the accepted forms. TDD ledger: E-4
-- and E-5 authored RED on 0.4.101, flip GREEN here; C-2 gains the end-to-end
-- half (a real cycle's apply refused not_owner on the proposal path).

CREATE OR REPLACE FUNCTION ckp.update_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id      text := p_payload->>'id';
  v_patch   jsonb := p_payload->'patch';
  v_proj    text := ckp._project();
  v_cur     jsonb;
  v_type    text;
  v_ns      text;
  v_propmap jsonb;
  v_shaped  boolean;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_id IS NULL OR btrim(v_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_required'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  -- 0.4.102 (E-5) — ONE ID VOCABULARY, READ AND WRITE ALIKE. instance.get has
  -- resolved bare, ckp://Type#id and urn:ckp:instance:<id> forms since 0.4.90;
  -- this verb kept looking up ckp.instances.id directly, so a caller could READ
  -- a fact by the @id a create reply stamped and could not PATCH it with the
  -- same string — and the refusal said unknown_instance, which points at
  -- existence when the defect was spelling. Same resolver, second caller: a
  -- verb that re-implements the resolver forks the id vocabulary, exactly as a
  -- probe that re-implements the gate tests the probe.
  v_id := ckp._resolve_id(v_id);
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id,
      'hint', 'accepted id forms: the bare instance id, the stamped @id (ckp://Type#id), and urn:ckp:instance:<id>'); END IF;

  v_type := v_cur->>'type';
  v_ns   := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;

  -- declared property map for the instance's type (same read as create_typed).
  -- 0.4.51: composed-aware, because a patch is a WRITE and must resolve keys the
  -- same way the gate will judge them. Refusing an undeclared patch key earlier,
  -- with the declared set named, is strictly better than sealing it under the
  -- type's namespace and letting the gate refuse the whole body.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_cur := v_cur - 'participant';   -- re-resolved by ckp.seal from any supplied claims

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    CONTINUE WHEN v_key IN ('id', 'type', '@id');   -- not patchable via this path
    IF position(':' in v_key) > 0 THEN
      -- 0.4.96 (E-3) — BEING AN IRI IS NOT BEING DECLARED.
      -- This branch passed any key containing ':' straight through on the
      -- strength of its FORM. The bare form was checked against the declared
      -- set and refused; the SAME property spelled as a full IRI was accepted.
      -- Measured: patch {'weightNonsense': …} refuses undeclared_patch_key,
      -- patch {'https://…core#weightNonsense': …} lands on the sealed instance.
      -- Nothing downstream catches it either — no shape targets a property that
      -- does not exist, so it conforms VACUOUSLY. That is the exact trap this
      -- composed-aware path was built to close, surviving inside it, and it was
      -- found only because a control that had been passing for the wrong reason
      -- was made to assert the reason.
      --
      -- The check is by VALUE, because _propmap maps localname -> IRI. On an
      -- UNSHAPED type it is deliberately skipped: there is no declared contract
      -- to check against, and refusing would invent one the surface never made.
      IF v_shaped AND NOT EXISTS (
           SELECT 1 FROM jsonb_each_text(v_propmap) m WHERE m.value = v_key) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type, 'form', 'absolute-iri',
                                  'hint', 'spelling the namespace out does not declare a property',
                                  'declared', (SELECT jsonb_agg(m.value ORDER BY m.value)
                                                 FROM jsonb_each_text(v_propmap) m));
      END IF;
      v_keyiri := v_key;                                    -- declared, in IRI form
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
    END IF;
    -- 0.4.102 (E-4) — "THE TRIPLE A CLIENT CANNOT WRITE", MADE TRUE. The
    -- germinate guard (0.4.89) says who may re-germinate by reading ownedBy;
    -- the apply gate (0.4.99) says who may enact by reading ownedBy. But
    -- ownedBy itself was an ordinary declared property, so ANY party could
    -- rewrite it through this verb and void both gates in one step — measured
    -- on a virgin 0.4.101: a non-owner moved a Project from tdd-e4-owner to
    -- tdd-e4-attacker with a plain instance.update. Ownership is server-derived
    -- at germination and there is NO transfer verb; that absence is a filed
    -- finding, not a licence to patch. The guard sits AFTER key resolution so
    -- every spelling — bare, CURIE, full IRI — meets it (the E-3 lesson).
    IF v_keyiri = 'https://conceptkernel.org/ontology/v3.11/core#ownedBy' THEN
      RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
        'error', 'ownership_not_patchable', 'key', v_keyiri, 'id', v_id,
        'hint', 'ckp:ownedBy is server-derived at germination and no transfer verb exists — '
                'both the germinate guard and the apply gate read this triple, so a patchable '
                'owner voids both. Ownership moves only when a governed transfer verb ships.');
    END IF;
    -- projectKind is the quorum floor (C-1/L-8): a stranger flipping a shared
    -- project to personal drops the floor to 1 and self-approves — the same
    -- takeover as rewriting the owner, one link over. Bind only what declared
    -- itself, exactly as apply's gate does: a declared owner gates the field,
    -- an unowned instance imposes nothing.
    IF v_keyiri = 'https://conceptkernel.org/ontology/v3.11/core#projectKind' THEN
      DECLARE
        v_owner text := v_cur->>'https://conceptkernel.org/ontology/v3.11/core#ownedBy';
        v_me    text := NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), '');
      BEGIN
        IF v_owner IS NOT NULL THEN
          v_me := CASE WHEN v_me IS NULL THEN NULL
                       ELSE 'urn:ckp:participant:'||ckp._slug(v_me) END;
          IF v_me IS DISTINCT FROM v_owner THEN
            RETURN jsonb_build_object('ok', false, 'refused', true, 'sqlstate', '42501',
              'error', 'not_owner', 'key', v_keyiri, 'owner', v_owner,
              'hint', 'ckp:projectKind is the quorum floor: only the declared owner may move '
                      'it. An unowned instance imposes nothing — the 0.4.81 rule.');
          END IF;
        END IF;
      END;
    END IF;
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1))
    || ckp._stamped(v_id)
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
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
