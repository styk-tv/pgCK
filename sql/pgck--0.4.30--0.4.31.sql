-- pgck 0.4.30 -> 0.4.31 — P0-E: the epoch is produced by a sealed Materialization (pgCK#28).
--
-- The epoch was a counter: bump_epoch advanced an integer and recompiled plans,
-- but nothing SEALED the rebuild, so 'valid at epoch N' named no artifact. Now
-- every governed apply seals, atomically in the apply txn:
--   * a ckp:Epoch  (the ordinal + the surfaceDigest of its enforcement surface)
--   * a ckp:Materialization (materializes the kernel, from/toEpoch, source +
--     surface digests, producesEpoch -> the Epoch) gated by MaterializationShape.
-- If either fails its shape gate the whole apply rolls back: a bumped epoch with
-- no valid Materialization cannot commit. And NO GOVERNED OP WITHOUT A PROJECTOR
-- — propose_change refuses ops that cannot project a change (default-deny)
-- instead of sealing an inert 'applied'.
-- Adds ckp._surface_digest (deterministic sha256 over a shapes graph, so the
-- surfaceDigest is a re-derivable claim). Bodies byte-identical to the baseline.

CREATE OR REPLACE FUNCTION ckp._surface_digest(p_graph bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_iri text; v_concat text;
BEGIN
  v_iri := pgrdf.graph_iri(p_graph);
  SELECT COALESCE(string_agg(
           (j->>'s')||'|'||(j->>'p')||'|'||(j->>'o'), chr(10)
           ORDER BY (j->>'s'), (j->>'p'), (j->>'o')), '')
    INTO v_concat
  FROM pgrdf.sparql(format(
    'SELECT ?s ?p ?o WHERE { GRAPH <%s> { ?s ?p ?o } }', v_iri)) j;
  RETURN encode(digest(convert_to(v_concat, 'UTF8'), 'sha256'), 'hex');
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
  v_proj      text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
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
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
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
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = 'pgCK'), 1);
    v_comp_e int;
    v_srcd   text;
    v_surfd  text;
    v_kiri   text := format('urn:ckp:%s/kernel/ck', v_proj);
    v_eiri   text;
    v_miri   text;
  BEGIN
    v_epoch := ckp.bump_epoch('pgCK');           -- recompiles plans + clears cache (same txn)
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

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'applied', v_applied,
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
  -- not editing the list.
  v_ops    text[] := ARRAY['add_class','add_property','set_transition_map','add_affordance'];
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
    'proposalDetail',    COALESCE(p_payload->'detail', '{}'::jsonb)
  );
  PERFORM ckp.seal(v_pid, v_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_pid, 'proposal_iri', 'ckp://Proposal#'||v_pid,
                            'state', 'pending', 'op', v_op, 'verified', ckp.verify(v_pid));
END;
$function$
;

-- Ring-1: replacements + the new helper must land the same ring as installs.
DO $floor_0431$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT pr.oid, pr.prokind FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
    WHERE n.nspname = 'ckp' AND pr.prokind IN ('f','p')
  LOOP
    IF p.prokind = 'f' THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    ELSE
      EXECUTE format('ALTER PROCEDURE %s OWNER TO ck_substrate', p.oid::regprocedure);
      EXECUTE format('ALTER PROCEDURE %s SET search_path = ckp, public, pg_temp', p.oid::regprocedure);
    END IF;
  END LOOP;
END
$floor_0431$;

REVOKE ALL ON FUNCTION ckp._surface_digest(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._surface_digest(bigint) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._surface_digest(bigint) TO ck_substrate;

CALL ckp._enforce_internal_floor();
