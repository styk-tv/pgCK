-- pgck 0.3.3 -> 0.3.4 — CKP v3.9 Track D (the governance type plane).
-- This migration accretes Track D's SQL across CI-D-5 / CI-D-4 / CI-D-3 / CI-D-2; v0.3.4 ships
-- at the CI-D-1 flip. A SHACL-shape / type change lands ONLY via proposal → quorum vote →
-- apply, with a complete proof chain. A direct attempt is structurally impossible (CI-A); a
-- dispatch attempt on the instance plane is plane-rejected (CI-B). The governance vocabulary +
-- shapes were forward-ported in CI-D-6 (ontology/core.ttl).

-- ============================================================================
-- CI-D-5 (index 10) — kernel.propose_change (seal a Proposal{pending}).
-- ============================================================================
-- v3.9 §5: a Proposal is DATA about a future type change — not yet the type. The op-set is a
-- closed enum; the payload is field-gated in plpgsql (so the TTL construction below cannot
-- inject — ckp.seal's own validation only checks required-props against the kernel graph, not
-- the full ProposalShape), then validated against ProposalShape (the authoritative SHACL gate,
-- via CI-B-3 validate_report), then sealed (instances + ledger + proof HMAC chain).

CREATE OR REPLACE FUNCTION ckp.propose_change(p_kernel_urn text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $prop$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_core   int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_ops    text[] := ARRAY['add_class','add_property','modify_shape_constraint','add_affordance',
                           'set_transition_map','set_quorum','set_materialize_policy'];
  v_op     text := p_payload->>'op';
  v_about  text := COALESCE(p_payload->>'about', p_kernel_urn);
  v_quorum int;
  v_pid    text;
  v_body   jsonb;
  v_ttl    text;
  v_report jsonb;
BEGIN
  -- 1. INJECTION-SAFE FIELD GATE (mirrors ProposalShape; makes step 2's TTL construction safe).
  IF v_op IS NULL OR NOT (v_op = ANY(v_ops)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal_op', 'op', v_op,
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
    'proposalDetail',    COALESCE(p_payload->'detail', '{}'::jsonb)
  );
  PERFORM ckp.seal(v_pid, v_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_pid, 'proposal_iri', 'ckp://Proposal#'||v_pid,
                            'state', 'pending', 'op', v_op, 'verified', ckp.verify(v_pid));
END;
$prop$;

COMMENT ON FUNCTION ckp.propose_change(text, jsonb) IS
  'CI-D-5: seal a ckp:Proposal{pending} (a typed op-set) — field-gated, ProposalShape-validated, '
  'then sealed. The change is DATA about the type until quorum (CI-D-4) applies it (CI-D-3).';

ALTER FUNCTION ckp.propose_change(text, jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-D-4 (index 9) — kernel.vote + quorum.
-- ============================================================================
-- v3.9 §5: a Vote is sealed ckp:about a pending Proposal; the quorum check COUNTs approve-votes
-- vs the Proposal's sealed ckp:requiresQuorum. A human approval is a ckp:Vote sealed by a human
-- identity — indistinguishable in the audit trail from any other vote. Same injection-safe
-- field-gate → VoteShape → seal discipline as propose_change.

CREATE OR REPLACE FUNCTION ckp.vote(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $vote$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_core      int  := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_about     text := p_payload->>'about';   -- the Proposal @id (IRI)
  v_value     text := p_payload->>'value';   -- approve | reject
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_vote_value', 'value', v_value);
  END IF;
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;

  -- 2. the Proposal must exist and still be pending.
  SELECT body INTO v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending',
                              'state', v_prop->>(C||'proposalState'));
  END IF;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);

  v_vid := 'vote-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 3. authoritative SHACL gate (VoteShape) — values field-validated, so the TTL is safe.
  v_ttl := '@prefix ckp: <'||C||'> .'||chr(10)||
           '<ckp://Vote#'||v_vid||'> a ckp:Vote ; ckp:about <'||v_about||'> ; '||
           'ckp:voteValue "'||v_value||'" .';
  v_report := ckp.validate_report(v_ttl, v_core);
  IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shape_violation', 'violations', v_report->'violations');
  END IF;

  -- 4. seal the Vote (sealed by the session identity — a human approval is indistinguishable).
  v_body := jsonb_build_object(
    'type',         C||'Vote',
    '@id',          'ckp://Vote#'||v_vid,
    C||'about',     v_about,
    C||'voteValue', v_value
  );
  PERFORM ckp.seal(v_vid, v_body);

  -- 5. quorum check: COUNT approve-votes about this Proposal vs requiresQuorum.
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote'
      AND body->>(C||'about') = v_about
      AND body->>(C||'voteValue') = 'approve';

  RETURN jsonb_build_object('ok', true, 'vote', v_vid, 'proposal', v_about, 'value', v_value,
                            'approvals', v_approvals, 'quorum', v_quorum,
                            'quorum_met', v_approvals >= v_quorum, 'verified', ckp.verify(v_vid));
END;
$vote$;

COMMENT ON FUNCTION ckp.vote(jsonb) IS
  'CI-D-4: seal a ckp:Vote about a pending Proposal; report approve-count vs requiresQuorum. '
  'quorum_met=true makes the Proposal eligible for kernel.apply (CI-D-3).';

ALTER FUNCTION ckp.vote(jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-D-3 (index 8) — kernel.apply cascade (gated on quorum; all-or-nothing).
-- ============================================================================
-- v3.9 §5: ONE transaction — gate on quorum, advance the kernel epoch (recompile plans + clear
-- the engine plan cache, via CI-C-2 bump_epoch = "DATA shape version advances"), and mark the
-- Proposal applied with a fresh ledger/proof entry (the proof chain proposal → votes → applied
-- epoch is complete). All-or-nothing: any failure rolls the whole cascade back. The full typed-op
-- ontology mutation via caller-Turtle is the fenced raw_ttl path (CI-D-2); D-3 lands the cascade,
-- the epoch advance, and the governed proof chain.

CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $apply$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.8/core#';
  v_about     text := p_payload->>'about';   -- the Proposal @id (IRI)
  v_prop      jsonb;
  v_pid       text;
  v_quorum    int;
  v_approvals int;
  v_epoch     int;
  v_new_body  jsonb;
BEGIN
  -- 1. field gate.
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  -- 2. the Proposal must exist + still be pending.
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  -- 3. QUORUM GATE — COUNT approvals vs the Proposal's sealed requiresQuorum.
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  -- 4. CASCADE (one txn). _recompile + epoch advance, then mark the Proposal applied.
  v_epoch := ckp.bump_epoch('pgCK');   -- recompile plans + pgrdf.plan_cache_clear() + epoch++

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_prop->>(C||'proposalOp'), 'approvals', v_approvals,
                            'verified', ckp.verify(v_pid));
END;
$apply$;

COMMENT ON FUNCTION ckp.apply(jsonb) IS
  'CI-D-3: apply a quorum-satisfied Proposal — advance the kernel epoch (recompile + cache clear) '
  'and seal the Proposal applied, all-or-nothing. Below quorum → quorum_not_met (no change).';

ALTER FUNCTION ckp.apply(jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- ============================================================================
-- CI-D-2 (index 7) — fenced raw_ttl + materialization policy.
-- ============================================================================
-- v3.9 §5.2: the ONE caller-Turtle path. The caller's TTL is parsed by the Rust engine into a
-- scratch graph (pgrdf.parse_turtle — ZERO SQL string-building, so a hostile payload cannot
-- inject), then validated against a META-FENCE the caller cannot modify: only ontology-meta
-- predicates (rdf/rdfs/owl/sh) are admitted — never instance data (ckp:* data predicates) nor
-- foreign-namespace triples. In production the staged graph is then copy_graph'd into the kernel
-- graph under elevated quorum + dropped, one txn; D-2 lands the parse-safely + meta-fence core.

CREATE OR REPLACE FUNCTION ckp.stage_ttl(p_ttl text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $stage$
DECLARE
  v_iri       text := 'urn:ckp:stage:'||pg_backend_pid();
  v_scratch   int;
  v_quads     bigint;
  v_forbidden jsonb;
BEGIN
  -- 1. STAGE — parse the caller's TTL via the engine into a scratch graph. Never concatenated
  --    into SQL; a malformed payload fails in the parser, not in our code.
  v_scratch := pgrdf.add_graph(v_iri);   -- get-or-create BY IRI (stable id; no fixed-id collision)
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    v_quads := pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:stage#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'parse_error', 'detail', SQLERRM);
  END;

  -- 2. META-FENCE — admit only ontology-meta predicates (rdf/rdfs/owl/sh). Any other predicate
  --    (instance data uses ckp:* data predicates; foreign triples use other namespaces) is a
  --    fence violation. The caller may EXTEND the type ontology, never inject data.
  SELECT jsonb_agg(DISTINCT j->>'p') INTO v_forbidden
  FROM pgrdf.sparql(format($q$
    SELECT ?p WHERE { GRAPH <%s> { ?s ?p ?o }
      FILTER( !STRSTARTS(STR(?p), "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2000/01/rdf-schema#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/2002/07/owl#")
           && !STRSTARTS(STR(?p), "http://www.w3.org/ns/shacl#") ) }
  $q$, v_iri)) j;

  PERFORM pgrdf.clear_graph(v_scratch);

  IF v_forbidden IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fence_violation',
                              'forbidden_predicates', v_forbidden, 'staged_quads', v_quads);
  END IF;
  RETURN jsonb_build_object('ok', true, 'staged_quads', v_quads, 'fenced', 'ontology-meta-only');
END;
$stage$;

COMMENT ON FUNCTION ckp.stage_ttl(text) IS
  'CI-D-2: the fenced caller-Turtle path — Rust-parse into a scratch graph, then admit only '
  'ontology-meta predicates (rdf/rdfs/owl/sh). Instance data + foreign triples are fence-rejected.';

-- The sealed materialization policy (v3.9 §5.4): trigger ∈ {batch, on_seal, governance-manual},
-- profile ∈ {rdfs, owl-rl}. Stored as governed config.
CREATE OR REPLACE FUNCTION ckp.set_materialize_policy(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $matpol$
DECLARE
  v_trigger text := p_payload->>'trigger';
  v_profile text := p_payload->>'profile';
BEGIN
  IF v_trigger IS NULL OR v_trigger NOT IN ('batch','on_seal','governance-manual') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_trigger', 'trigger', v_trigger);
  END IF;
  IF v_profile IS NULL OR v_profile NOT IN ('rdfs','owl-rl') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_profile', 'profile', v_profile);
  END IF;
  INSERT INTO ckp.config(k,v) VALUES ('materialize_trigger', v_trigger) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
  INSERT INTO ckp.config(k,v) VALUES ('materialize_profile', v_profile) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
  RETURN jsonb_build_object('ok', true, 'trigger', v_trigger, 'profile', v_profile);
END;
$matpol$;

COMMENT ON FUNCTION ckp.set_materialize_policy(jsonb) IS
  'CI-D-2: sealed materialization policy — trigger ∈ {batch, on_seal, governance-manual}, '
  'profile ∈ {rdfs, owl-rl}. on_seal is reserved for small kernel graphs.';

ALTER FUNCTION ckp.stage_ttl(text)             OWNER TO ck_substrate;
ALTER FUNCTION ckp.set_materialize_policy(jsonb) OWNER TO ck_substrate;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
