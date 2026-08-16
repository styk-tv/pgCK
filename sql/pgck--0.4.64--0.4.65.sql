-- pgck 0.4.64 → 0.4.65 — SEALED PROOF OBLIGATIONS (§5b, ruling-1786820448218277000)
--
-- THE DESIGN FACT THIS STANDS ON: ckp.proof carries no uniqueness — N proofs
-- per fact was PLACED so the seal's exit could grow by agreement. This release
-- makes that joint operational: a proof OBLIGATION is a governed proof-producer,
-- registered through propose→vote→apply under the new op add_proof_obligation
-- (the seal-exit dual of add_affordance: affordances-in open capability,
-- obligations-out close it), run by ckp.seal after the shape gate for every
-- candidate of its target type. A failing obligation REFUSES the seal — that is
-- its point. Each satisfaction is appended as a ckp.proof row whose method names
-- the agreement ('obligation:<name>'), so "which checks did this seal pass" is
-- a read, not an inference.
--
-- BOUNDS. Per-kernel blast radius (the registry row names the project); a FIXED
-- registry of pure-read checks calling the substrate's own internals — an
-- obligation may only NAME a check the substrate implements, exactly the
-- discipline P0-E applies to ops; removal travels the same governed road
-- (detail.active=false); an obligation naming an unimplemented check fails
-- CLOSED at seal rather than silently skipping a guard two parties agreed to.
-- External effects stay out until the validity≠safety gate is specified.
--
-- THE DEBUT CHECK, digest-match: "the surfaceDigest this candidate cites was
-- sealed by an Epoch" — and when the candidate also cites an epoch number, the
-- pair must sit on ONE sealed Epoch. The shape gate judges FORM; this judges
-- REFERENCE. It closes the fabricated-digest hole ck-lib-js measured
-- (finding-1786716799509380000: an invented sixty-four-hex digest sealed
-- verified:true) in the mechanism's first act.
--
-- Changed: propose_change (op allowlisted + P0-E detail gate), apply (4d
-- projector), seal (1b runner + 4b obligation-proof rows), wave_signals
-- (active obligations readable through the door), bootstrap_kernel (registry
-- table). New: register_proof_obligation, _oblig_digest_match,
-- _run_proof_obligations, table ckp.proof_obligations (footer).
CREATE OR REPLACE PROCEDURE ckp.bootstrap_kernel()
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
BEGIN
  CREATE TABLE IF NOT EXISTS ckp.instances (
    id TEXT PRIMARY KEY, body JSONB NOT NULL,
    meta JSONB NOT NULL DEFAULT '{}'::jsonb,
    ts_created TIMESTAMPTZ NOT NULL DEFAULT now(),
    ts_updated TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS ckp.ledger (
    seq BIGSERIAL PRIMARY KEY, instance_id TEXT NOT NULL,
    body_sha256 TEXT NOT NULL, sig TEXT NOT NULL,
    prev_seq BIGINT, ts TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS ckp.proof (
    id BIGSERIAL PRIMARY KEY, about TEXT NOT NULL,
    method TEXT NOT NULL, digest TEXT NOT NULL,
    verified_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS ckp.outbox (
    seq           BIGSERIAL PRIMARY KEY,
    ledger_seq    BIGINT NOT NULL REFERENCES ckp.ledger(seq) ON DELETE CASCADE,
    subject       TEXT NOT NULL,
    payload       BYTEA NOT NULL,
    headers       JSONB NOT NULL DEFAULT '{}'::jsonb,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    enqueued_at   TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE INDEX IF NOT EXISTS ckp_outbox_seq_idx ON ckp.outbox(seq);
  -- 0.4.61 — the adoption pin ledger (ck-dev's defect: a module composed under a
  -- sourceDigest of sixty-four zeros; the pin was judged by AdoptionShape and
  -- consulted by NOTHING). The substrate cannot verify a FILE-BYTE digest from
  -- triples, so the honest split is: file verification belongs to the loader at
  -- the file door; the substrate pins the GRAPH's canonical digest at first
  -- composition and makes later drift DETECTABLE. Trust-on-first-sight, named.
  CREATE TABLE IF NOT EXISTS ckp.adoption_pins (
    graph_iri    TEXT PRIMARY KEY,
    graph_digest TEXT NOT NULL,
    pinned_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  -- 0.4.65 — the obligation registry (§5b): governed proof-producers run at
  -- seal-exit. Registered only through add_proof_obligation (propose→vote→
  -- apply); consulted by ckp.seal via ckp._run_proof_obligations.
  CREATE TABLE IF NOT EXISTS ckp.proof_obligations (
    project     TEXT NOT NULL,
    obligation  TEXT NOT NULL,
    target_type TEXT NOT NULL,
    check_name  TEXT NOT NULL,
    added_epoch INTEGER,
    active      BOOLEAN NOT NULL DEFAULT true,
    ts_added    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project, obligation)
  );
  DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
  CREATE TRIGGER ckp_ledger_after_insert
    AFTER INSERT ON ckp.ledger
    FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();

  -- CI-A-4: floor the runtime-created tables (instances/ledger/proof/outbox).
  CALL ckp._enforce_internal_floor();

  -- 0.4.57 — RESET THE ENGINE'S TERM CACHE. An aborted seal (every negative
  -- control in the suite is one) can leave pgrdf's shmem term cache in a state
  -- where a quad STORES but SHACL cannot SEE it — measured here as an Edge
  -- candidate whose serialized created_at triple was present in the TTL and
  -- absent from the validator's view, refusing conformant work. The engine's
  -- own remedy is pgrdf.shmem_reset() after any aborted seal; this bootstrap
  -- is the per-file entry point of every test, so each file starts clean.
  -- Guarded: older engines without the function skip silently.
  IF to_regprocedure('pgrdf.shmem_reset()') IS NOT NULL THEN
    PERFORM pgrdf.shmem_reset();
  END IF;

  -- 0.4.64 — the dev/test bootstrap NAMES its service identity, per the refusal
  -- ruling: unattributed seals refuse, and the sanctioned operator path is an
  -- explicitly declared service identity. Session-scoped, constant (never a
  -- fresh uuid — one suite, one accountable name), and only a default: a test
  -- that sets its own requester overrides it, and a test that must exercise
  -- the refusal clears it. This procedure is superuser-only; a participant
  -- cannot reach it.
  PERFORM set_config('ckp.requester', 'svc:bench-bootstrap', false);
END;
$procedure$
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
  v_ops    text[] := ARRAY['add_class','add_property','set_transition_map','add_affordance','add_proof_obligation'];
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
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 1);
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
    PERFORM ckp.seal('epoch-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Epoch', '@id', v_eiri,
      C||'epoch', to_jsonb(v_epoch),
      C||'surfaceDigest', v_surfd));
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

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'applied', v_applied,
                            'verified', ckp.verify(v_pid));
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
    N||'producedBy', N||'createdBy', N||'sealedAtEpoch', N||'conformsToShape'
  ];

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
  BEGIN
    v_comp := ckp._composed_shapes(v_project);
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
    IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'ckp.seal: payload fails the composed shape gate: %',
        COALESCE(ckp._report_summary(v_report), v_report::text);
    END IF;
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

CREATE OR REPLACE FUNCTION ckp.wave_signals(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  W text := 'https://conceptkernel.org/ontology/v3.11/wave#';
  v_proj  text := ckp._project();
  v_pass  int  := (p_payload->>'pass')::int;
  -- component alias convention: c-<project, dashes stripped> (c-pgck, c-pgckmcp);
  -- override with {component} where the convention doesn't hold (ck-lib-js → c-cklib).
  v_comp  text := COALESCE(p_payload->>'component', W||'c-'||replace(v_proj,'-',''));
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
  v_this jsonb; v_next jsonb; v_sig jsonb;
BEGIN
  -- THIS PASS — everything stamped with the number, any of the six stamps.
  IF v_pass IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'type', regexp_replace(i.body->>'type','^.*[/#]',''),
        'by',   i.body->>(C||'producedBy'),
        'judged', (i.body ? (C||'conformsToShape'))) ORDER BY i.ts_created), '[]'::jsonb)
      INTO v_this
    FROM ckp.instances i
    WHERE COALESCE((i.body->>(W||'discoveredAtPass'))::numeric, -1) = v_pass
       OR COALESCE((i.body->>(W||'resolvedAtPass'))::numeric,  -1) = v_pass
       OR COALESCE((i.body->>(W||'ruledAtPass'))::numeric,     -1) = v_pass
       OR COALESCE((i.body->>(W||'opAtPass'))::numeric,        -1) = v_pass
       OR COALESCE((i.body->>(W||'rebasedAtPass'))::numeric,   -1) = v_pass
       OR i.body->>(W||'forPass') = W||'pass-'||v_pass;
  END IF;

  -- THE NEXT-PASS QUEUE — derived, so carry-over is never a memory exercise.
  v_next := jsonb_build_object(
    'openFindings', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'label', left(COALESCE(i.body->>'http://www.w3.org/2000/01/rdf-schema#label',
                               i.body->>(W||'label')), 140),
        'by', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Finding' AND i.body->>(W||'findingState') = 'open'),
    'pendingProposals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'about', i.body->>(C||'about'), 'op', i.body->>(C||'proposalOp'),
        'by', i.body->>(C||'createdBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = C||'Proposal'
        AND i.body->>(C||'proposalState') = 'pending'
        AND NOT i.body ? (C||'retiredAtEpoch')),
    'inbox', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', i.id, 'opKind', i.body->>(W||'opKind'),
        'from', i.body->>(C||'producedBy')) ORDER BY i.ts_created), '[]'::jsonb)
      FROM ckp.instances i
      WHERE i.body->>'type' = W||'Operation'
        -- 0.4.62: opTarget has no canonical spelling — components address this
        -- kernel as its wave alias, its kernel URN, or its kernel/ck graph. Two
        -- escalations from ck-dev sat unseen for a day because this matched the
        -- alias alone. Same defect family as the intoProject spellings.
        AND i.body->>(W||'opTarget') IN (v_comp,
              'urn:ckp:'||v_proj||'/kernel', 'urn:ckp:'||v_proj||'/kernel/ck')));

  -- SIGNALS — health counts a third party can recompute. Never one boolean.
  v_sig := jsonb_build_object(
    'unjudged',       (SELECT count(*) FROM ckp.instances i
                       WHERE COALESCE((i.body->>(C||'sealedAtEpoch'))::numeric, -1) >= 1
                         AND NOT i.body ? (C||'conformsToShape')),
    'preEnforcement', (SELECT count(*) FROM ckp.instances i
                       WHERE NOT i.body ? (C||'sealedAtEpoch')),
    'anonymousSeals', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>(C||'createdBy') LIKE 'urn:ckp:participant:anon%'),
    'openFindings',   (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = W||'Finding'
                         AND i.body->>(W||'findingState') = 'open'),
    'pendingProposalsFleet', (SELECT count(*) FROM ckp.instances i
                       WHERE i.body->>'type' = C||'Proposal'
                         AND i.body->>(C||'proposalState') = 'pending'
                         AND NOT i.body ? (C||'retiredAtEpoch')),
    -- 0.4.65 (§5b): the agreements guarding this kernel's seal-exit. A guard
    -- two parties agreed to must be READABLE by the third who meets it.
    'obligations',    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                         'obligation', o.obligation,
                         'targetType', regexp_replace(o.target_type,'^.*[/#]',''),
                         'check', o.check_name,
                         'sinceEpoch', o.added_epoch) ORDER BY o.obligation), '[]'::jsonb)
                       FROM ckp.proof_obligations o
                       WHERE o.active AND o.project = v_proj));

  RETURN jsonb_build_object(
    'ok', true, 'kernel', v_proj, 'component', v_comp, 'epoch', v_epoch,
    'pass', v_pass, 'thisPass', COALESCE(v_this, '[]'::jsonb),
    'next', v_next, 'signals', v_sig,
    'boundary', 'THIS pass = facts stamped with its number + the epochs they advanced; closed at Index seal. NEXT pass = this `next` object AT close — derived, never remembered. NEXT wave = when bindsRoot moves. unjudged means sealedAtEpoch>=1 with conformsToShape ABSENT: admitted, ledgered, judged by nothing — the fence.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.register_proof_obligation(p_prop jsonb, p_project text, p_epoch integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_detail  jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_ob      text  := v_detail->>'obligation';
  v_type    text  := v_detail->>'targetType';
  v_chk     text  := v_detail->>'check';
  v_active  boolean;
  v_name_re text  := '^[a-z][a-z0-9-]*$';
  v_iri_re  text  := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  -- THE FIXED CHECK REGISTRY. Widening it means implementing a pure-read check
  -- in ckp._run_proof_obligations' CASE, never editing this list alone — the
  -- P0-E sibling: a check that cannot run is refused at registration.
  v_checks  text[] := ARRAY['digest-match'];
BEGIN
  IF v_ob IS NULL OR v_ob !~ v_name_re THEN
    RAISE EXCEPTION 'add_proof_obligation: obligation must be a lowercase dashed name, got %', v_ob; END IF;
  BEGIN
    v_active := COALESCE((v_detail->>'active')::boolean, true);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'add_proof_obligation: active must be a boolean, got %', v_detail->>'active'; END;
  IF NOT v_active THEN
    -- deactivation: the same governed road out that led in. The row stays —
    -- WHICH obligation guarded WHICH epochs remains answerable.
    UPDATE ckp.proof_obligations SET active = false
      WHERE project = p_project AND obligation = v_ob;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'add_proof_obligation: no obligation named % on this kernel to deactivate', v_ob; END IF;
    RETURN v_ob;
  END IF;
  IF v_type IS NULL OR v_type !~ v_iri_re THEN
    RAISE EXCEPTION 'add_proof_obligation: targetType must be a type IRI, got %', v_type; END IF;
  IF v_chk IS NULL OR NOT (v_chk = ANY(v_checks)) THEN
    RAISE EXCEPTION 'add_proof_obligation: check % is not in the fixed registry % — an obligation names a check the substrate implements; widening the registry means implementing one, not naming one', v_chk, v_checks; END IF;
  INSERT INTO ckp.proof_obligations(project, obligation, target_type, check_name, added_epoch, active)
  VALUES (p_project, v_ob, v_type, v_chk, p_epoch, true)
  ON CONFLICT (project, obligation) DO UPDATE
    SET target_type = EXCLUDED.target_type, check_name = EXCLUDED.check_name,
        added_epoch = EXCLUDED.added_epoch, active = true;
  RETURN v_ob;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._oblig_digest_match(p_instance_id text, p_body jsonb, p_project text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- THE DEBUT CHECK (§5b): "the surfaceDigest this candidate cites was sealed by
-- an Epoch." Pure read. Returns NULL on satisfaction, the refusal text
-- otherwise. Closes the fabricated-digest hole ck-lib-js measured
-- (finding-1786716799509380000): a wave:Pass citing an invented sixty-four-hex
-- digest sealed verified:true, because the shape gate judges FORM and nothing
-- judged REFERENCE. This check judges reference — against the sealed Epoch
-- instances themselves, never a parallel record.
--
-- Jurisdiction discipline: an ABSENT surfaceDigest is minCount's business (the
-- shape gate refuses it); this check rules only on a PRESENT citation. When the
-- candidate also cites an epoch number, the pair must sit on one sealed Epoch —
-- citing epoch 13 with epoch 12's digest is exactly the dishonesty this exists
-- to refuse.
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_digest text := p_body->>(C||'surfaceDigest');
  v_epoch  text := p_body->>(C||'epoch');
BEGIN
  IF v_digest IS NULL THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM ckp.instances i
             WHERE i.body->>'type' = C||'Epoch'
               AND i.body->>(C||'surfaceDigest') = v_digest
               AND (v_epoch IS NULL OR i.body->>(C||'epoch') = v_epoch)) THEN
    RETURN NULL;
  END IF;
  RETURN format('digest-match: the candidate cites surfaceDigest %s…%s but no sealed ckp:Epoch carries that surface — a citation must name a digest an Epoch sealed, exactly as sealed (ck_epochs lists them)',
                left(v_digest, 12),
                CASE WHEN v_epoch IS NOT NULL THEN ' at epoch '||v_epoch ELSE '' END);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._run_proof_obligations(p_instance_id text, p_type text, p_body jsonb, p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- Runs every ACTIVE obligation this kernel registered for the candidate's
-- declared type. Returns {satisfied: [names]} or {refused: <obligation>,
-- reason: <text>} — ckp.seal raises on refusal and appends one proof row per
-- satisfied name. Exact-type match: an obligation on wave:Pass does not reach
-- ckp:Epoch seals (the apply cascade), and ancestor-aware matching waits for
-- an agreement that wants it. An obligation naming a check this substrate does
-- not implement fails CLOSED — registration refuses it (register_proof_
-- obligation), and if one arrives anyway (downgrade skew), the seal refuses
-- rather than silently skipping a guard two parties agreed to.
DECLARE
  r      record;
  v_fail text;
  v_sat  jsonb := '[]'::jsonb;
BEGIN
  FOR r IN SELECT obligation, check_name FROM ckp.proof_obligations
           WHERE active AND project = p_project AND target_type = p_type
           ORDER BY obligation
  LOOP
    CASE r.check_name
      WHEN 'digest-match' THEN v_fail := ckp._oblig_digest_match(p_instance_id, p_body, p_project);
      ELSE v_fail := format('check %s is not implemented by this substrate — failing closed rather than skipping an agreed guard', r.check_name);
    END CASE;
    IF v_fail IS NOT NULL THEN
      RETURN jsonb_build_object('refused', r.obligation, 'reason', v_fail);
    END IF;
    v_sat := v_sat || to_jsonb(r.obligation);
  END LOOP;
  RETURN jsonb_build_object('satisfied', v_sat);
END;
$function$
;

-- The obligation registry itself. Fresh installs create it in the baseline DDL
-- and again defensively in bootstrap_kernel; the upgrade path creates it here.
-- The row stays on deactivation — WHICH obligation guarded WHICH epochs remains
-- answerable from the table alone.
CREATE TABLE IF NOT EXISTS ckp.proof_obligations (
  project     text NOT NULL,
  obligation  text NOT NULL,
  target_type text NOT NULL,
  check_name  text NOT NULL,
  added_epoch integer,
  active      boolean DEFAULT true NOT NULL,
  ts_added    timestamp with time zone DEFAULT now() NOT NULL,
  PRIMARY KEY (project, obligation)
);
-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
