-- pgck 0.4.66 → 0.4.67 — THE STRUCTURAL PLANE (§5b alignment; the owed half of
-- operation-1786864412791323000, confirmed by pgRDF in
-- confirmation-1786864613323583000)
--
-- Blank nodes are existential variables, not names: a SHACL-bearing graph
-- serializes to different bytes on every load forever, so a byte digest can
-- answer "same bytes" and never "same graph" (finding-1786862028710113000 —
-- pgck's surfaceDigest and adoption pins are COPY digests, bench-local).
-- This release adds the plane that survives:
--
--   ckp._structural_digest   first-degree bnode-signature digest, the FLEET
--                            algorithm byte-for-byte. Acceptance: three
--                            independent loads of the v3.11 core (two bench
--                            graphs, one test-rig graph) carry three byte
--                            digests and ONE structural digest, 9a791c6c… —
--                            reproduced by this function against the
--                            client-side tool's published pins. Interim seat:
--                            reads the engine's quad/dictionary tables
--                            (asserted only, fails loud on schema drift);
--                            pgRDF#117 (RDFC-1.0 in the engine) retires it.
--   Epoch seals              carry structuralDigest beside surfaceDigest —
--                            each plane named for what it pins; nobody minted
--                            early, the key ships with the code that derives it.
--   adoption_pins            gain structural_digest + nodeshapes/properties/
--                            asserted counts (the blank-node-immune third
--                            instrument); adoption.check reports both planes
--                            with the verdict asymmetry stated.
--   surface.grounding        the census as a verb: per graph, existential
--                            census, both digest planes, counts. {iri} form
--                            examines one brought graph — the §14.3 admission
--                            contract's fingerprint gate at pgck's door.
--   _op_to_ttl               NAMED shapes, never brackets: `[ a sh:NodeShape …
--                            ]` minted anonymous NodeShapes (and anonymous
--                            property shapes through the inner bracket) into
--                            the KERNEL graph — blank nodes in the doctrine,
--                            breaking byte-pinnability and making shapes
--                            unsupersedable by name. Caught by the
--                            doctrine-stays-existential-free fleet rule BEFORE
--                            any governed add_class fired on a live kernel.
--
-- Changed: bootstrap_kernel, apply, _op_to_ttl, _composed_shapes,
-- adoption_check, dispatch. New: _structural_digest, surface_grounding, and
-- the surface.grounding registry row (footer).
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
  -- 0.4.67: the structural plane joins the pin (reload-surviving digest +
  -- blank-node-immune counts). ADD COLUMN keeps pre-0.4.67 pins valid: their
  -- structural fields backfill at the next composition's re-pin or stay NULL,
  -- honestly reported as "pinned before the structural plane existed".
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS structural_digest TEXT;
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS nodeshapes INTEGER;
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS properties INTEGER;
  ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS asserted INTEGER;
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

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'applied', v_applied,
                            'verified', ckp.verify(v_pid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';            -- state names (no quote/space)
  v_op       text := p_prop->>(C||'proposalOp');
  v_detail   jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_class    text;
  v_path     text;
  v_min      int;
  v_dtype    text;
  v_dt_line  text := '';
  v_map      jsonb;
  v_fs       text;
  v_ts       text;
  v_ttl      text;
  -- 0.4.67 — NAMED SHAPES, NEVER BRACKETS. The `[ a sh:NodeShape … ]` form
  -- minted an anonymous NodeShape into the KERNEL graph — a blank node in the
  -- doctrine. That breaks two things at once: the doctrine stops being
  -- byte-pinnable (existential-free is the fleet rule, measured 22/22 ground
  -- on this kernel), and a shape nobody can name can never be superseded by
  -- name. Caught by the rule BEFORE any governed add_class ever fired on a
  -- live kernel — the first prevented defect of the alignment. The shape IRI
  -- is deterministic (project + local names + an 8-hex discriminator over the
  -- full IRIs), so re-applying the same op re-emits the same subject.
  -- Project segment from the SEALED producedBy — server-derived, never parsed
  -- from a caller field.
  v_seg      text := (regexp_match(COALESCE(p_prop->>(C||'producedBy'),''), '^urn:ckp:([^/]+)/kernel'))[1];
  v_shape    text;
BEGIN
  IF v_op = 'add_property' THEN
    v_class := v_detail->>'targetClass';
    v_path  := v_detail->>'path';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: targetClass must be an IRI, got %', v_class; END IF;
    IF v_path IS NULL OR v_path !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: path must be an IRI, got %', v_path; END IF;
    BEGIN
      v_min := COALESCE((v_detail->>'minCount')::int, 1);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'add_property: minCount must be an integer, got %', v_detail->>'minCount'; END;
    v_dtype := v_detail->>'datatype';
    IF v_dtype IS NOT NULL THEN
      IF v_dtype !~ v_iri_re THEN RAISE EXCEPTION 'add_property: datatype must be an IRI, got %', v_dtype; END IF;
      v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
    END IF;
    IF v_seg IS NULL THEN
      RAISE EXCEPTION 'add_property: cannot derive the project segment from the proposal''s producedBy — a shape must be NAMED into a kernel graph, never anonymous'; END IF;
    v_shape := format('urn:ckp:%s/shape/%s--%s--%s', v_seg,
                      ckp._slug(regexp_replace(v_class,'^.*[/#:]','')),
                      ckp._slug(regexp_replace(v_path,'^.*[/#:]','')),
                      left(md5(v_class||'|'||v_path),8));
    -- the PROPERTY shape is named too — `sh:property [ … ]` would put the
    -- blank node right back into the doctrine through the inner bracket.
    RETURN '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '<'||v_shape||'> a sh:NodeShape ; sh:targetClass <'||v_class||'> ; '||
           'sh:property <'||v_shape||'/p> .'||chr(10)||
           '<'||v_shape||'/p> sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' .';

  ELSIF v_op = 'add_class' THEN
    v_class := COALESCE(v_detail->>'class', v_detail->>'targetClass', p_prop->>(C||'about'));
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_class: class must be an IRI, got %', v_class; END IF;
    -- detail.properties[] WAS ACCEPTED AND SILENTLY DROPPED. The op emitted one
    -- quad (<class> a owl:Class) and reported graph_changed:true, so a caller
    -- who declared constraints got a class carrying none and no complaint --
    -- the same family as detail/proposalDetail and the inert epoch. Reported by
    -- pgCK.MCP against urn:ckp:pgck-mcp/type/ToolProjection: two property
    -- shapes sent, one quad applied, nothing validatable.
    --
    -- Emit the NodeShape too, with the same per-property gate add_property uses.
    -- A malformed property is REFUSED here, never dropped: silently narrowing a
    -- shape is un-enforcement nobody sees.
    IF v_seg IS NULL THEN
      RAISE EXCEPTION 'add_class: cannot derive the project segment from the proposal''s producedBy — a shape must be NAMED into a kernel graph, never anonymous'; END IF;
    v_shape := format('urn:ckp:%s/shape/%s--%s', v_seg,
                      ckp._slug(regexp_replace(v_class,'^.*[/#:]','')),
                      left(md5(v_class),8));
    v_ts := ''; v_ttl := '';
    IF jsonb_typeof(v_detail->'properties') = 'array' THEN
      FOR v_map IN SELECT jsonb_array_elements(v_detail->'properties') LOOP
        v_path := v_map->>'path';
        IF v_path IS NULL OR v_path !~ v_iri_re THEN
          RAISE EXCEPTION 'add_class: property path must be an IRI, got %', v_path; END IF;
        BEGIN
          v_min := COALESCE((v_map->>'minCount')::int, 1);
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'add_class: property minCount must be an integer, got %', v_map->>'minCount'; END;
        v_dtype := v_map->>'datatype';
        v_dt_line := '';
        IF v_dtype IS NOT NULL THEN
          IF v_dtype !~ v_iri_re THEN
            RAISE EXCEPTION 'add_class: property datatype must be an IRI, got %', v_dtype; END IF;
          v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
        END IF;
        -- named property shapes (…/p0, /p1, …): the inner bracket was the
        -- other half of the bnode emission — see the DECLARE note.
        v_fs := v_shape||'/p'||left(md5(v_path),8);
        v_ts := v_ts||' ; sh:property <'||v_fs||'>';
        v_ttl := v_ttl||'<'||v_fs||'> sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' .'||chr(10);
      END LOOP;
    END IF;
    IF v_ts = '' THEN
      -- bare declaration: a building block for a following add_property. NOTE it
      -- is admitted the moment it lands (_type_admitted accepts `a owl:Class`),
      -- so until a shape targets it an instance of this type validates
      -- VACUOUSLY. That window is a doctrine question, not a projector bug.
      RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
             '<'||v_class||'> a owl:Class .';
    END IF;
    RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
           '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '<'||v_class||'> a owl:Class .'||chr(10)||
           '<'||v_shape||'> a sh:NodeShape ; sh:targetClass <'||v_class||'>'||v_ts||' .'||chr(10)||
           v_ttl;

  ELSIF v_op = 'set_transition_map' THEN
    v_class := v_detail->>'targetClass';
    v_map   := v_detail->'map';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'set_transition_map: targetClass must be an IRI, got %', v_class; END IF;
    IF v_map IS NULL OR jsonb_typeof(v_map) <> 'object' THEN
      RAISE EXCEPTION 'set_transition_map: map must be an object {from:[to,…]}'; END IF;
    v_ttl := '@prefix ckp: <'||C||'> .'||chr(10);
    FOR v_fs IN SELECT jsonb_object_keys(v_map) LOOP
      IF v_fs !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad from-state %', v_fs; END IF;
      IF jsonb_typeof(v_map->v_fs) <> 'array' THEN
        RAISE EXCEPTION 'set_transition_map: map[%] must be an array of to-states', v_fs; END IF;
      FOR v_ts IN SELECT jsonb_array_elements_text(v_map->v_fs) LOOP
        IF v_ts !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad to-state %', v_ts; END IF;
        v_ttl := v_ttl || '<'||v_class||'> ckp:allowsTransition '||
                 '[ ckp:fromState "'||v_fs||'" ; ckp:toState "'||v_ts||'" ] .'||chr(10);
      END LOOP;
    END LOOP;
    RETURN v_ttl;

  END IF;
  -- Ops without a shape projection yet (modify_shape_constraint, set_quorum,
  -- set_materialize_policy) leave the graph unchanged here; add_affordance with a query
  -- is handled by ckp.apply's register step. Translators land as each is built.
  RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text DEFAULT 'demo'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_core int; v_kernel int; v_comp int; v_mod int;
  v_iri  text;
  v_cnt  int;
BEGIN
  v_core   := pgrdf.add_graph('urn:ckp:core');
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  v_comp   := pgrdf.add_graph(format('urn:ckp:%s/shapes/composed', p_project));
  PERFORM pgrdf.clear_graph(v_comp);
  PERFORM pgrdf.copy_graph(v_core,   v_comp);
  PERFORM pgrdf.copy_graph(v_kernel, v_comp);
  -- A2: every graph a sealed unsuperseded Adoption names joins the surface.
  -- Module-IRI-is-graph-IRI: the adopts value IS the graph. Fail CLOSED on a
  -- dangling or empty reference — a vanished module silently narrowing the
  -- gate is un-enforcement nobody would see.
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(p_project) LOOP
    v_mod := pgrdf.add_graph(v_iri);
    SELECT count(*) INTO v_cnt
      FROM pgrdf.sparql(format('SELECT ?s WHERE { GRAPH <%s> { ?s ?p ?o } } LIMIT 1', v_iri));
    IF v_cnt = 0 THEN
      RAISE EXCEPTION 'ckp._composed_shapes: adopted module graph % is absent or empty — a sealed Adoption names it, so composing without it would silently narrow the enforcement surface. Load the module graph or seal a Supersession.', v_iri;
    END IF;
    -- 0.4.61: pin the graph's canonical digest at FIRST composition. Verification
    -- happens in adoption.check / the oracle, never here — B4's rule: a report
    -- may be wrong cheaply, a gate may not, and a false drift-positive in the
    -- hot path would refuse every seal for the project. Detection, declared.
    -- 0.4.67: the pin carries BOTH planes plus the structural counts. The copy
    -- digest detects in-store drift; the structural digest is what a party on
    -- ANOTHER store verifies against (three loads of one module share it); the
    -- counts (NodeShapes/properties/asserted) are the blank-node-immune third
    -- instrument — the 27+11+4=42 arithmetic, per module.
    INSERT INTO ckp.adoption_pins(graph_iri, graph_digest, structural_digest, nodeshapes, properties, asserted)
    VALUES (v_iri, ckp._surface_digest(v_mod), ckp._structural_digest(v_mod),
      (SELECT count(*) FROM pgrdf.sparql(format(
         'SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/shacl#NodeShape> } }', v_iri))),
      (SELECT count(*) FROM pgrdf.sparql(format(
         'SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/ns/shacl#path> ?p } }', v_iri))),
      (SELECT count(*) FROM pgrdf._pgrdf_quads q WHERE q.graph_id = v_mod AND NOT q.is_inferred))
    ON CONFLICT (graph_iri) DO NOTHING;
    PERFORM pgrdf.copy_graph(v_mod, v_comp);
  END LOOP;
  -- Entailment is per-graph and pgrdf.validate does not entail, so the closure
  -- is computed HERE, once, rather than depended on at validate time.
  PERFORM pgrdf.materialize(v_comp);
  RETURN v_comp;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.adoption_check(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_proj text := ckp._project();
  v_iri  text;
  v_rows jsonb := '[]'::jsonb;
  v_pin  text; v_now text; v_drift boolean := false;
BEGIN
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(v_proj) LOOP
    SELECT graph_digest INTO v_pin FROM ckp.adoption_pins WHERE graph_iri = v_iri;
    v_now := ckp._surface_digest(pgrdf.add_graph(v_iri));
    IF v_pin IS NOT NULL AND v_pin <> v_now THEN v_drift := true; END IF;
    v_rows := v_rows || jsonb_build_object(
      'module', v_iri,
      'graphDigestNow', v_now,
      'graphDigestPinned', v_pin,
      'drifted', (v_pin IS NOT NULL AND v_pin <> v_now),
      -- 0.4.67: the structural plane, reported beside the copy plane. This is
      -- the value a party on ANOTHER store compares (finding-1786716790912211000:
      -- no consumer read path exposed a composed module's digest — this is that
      -- path, both planes, counts included). NULL structural pin = pinned
      -- before the structural plane existed; re-pins at next fresh composition.
      'structuralDigestNow', ckp._structural_digest(pgrdf.add_graph(v_iri)),
      'structuralDigestPinned', (SELECT p.structural_digest FROM ckp.adoption_pins p WHERE p.graph_iri = v_iri),
      'counts', (SELECT jsonb_build_object('nodeshapes', p.nodeshapes, 'properties', p.properties, 'asserted', p.asserted)
                   FROM ckp.adoption_pins p WHERE p.graph_iri = v_iri),
      'sourceDigest', (SELECT a.body->>(N||'sourceDigest') FROM ckp.instances a
                        WHERE a.body->>'type' = N||'Adoption'
                          AND a.body->>(N||'adopts') = v_iri
                        ORDER BY a.ts_created DESC LIMIT 1),
      'sourceDigestVerifiable', false,
      'why', 'sourceDigest is a FILE-BYTE sha256; a graph cannot recompute file bytes. Verify it where the file is loaded (pgRDF#118 is that seat). The substrate''s halves: the COPY pin detects in-store drift; the STRUCTURAL pin survives reload and is what a third party recomputes. Equal structural digests are evidence, not proof (first-degree); unequal ARE proof of difference.');
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj,
    'modules', v_rows, 'drifted', v_drift,
    'note', 'drifted:true means an adopted module''s graph no longer matches its first-composition pin — the module was swapped or edited under an unsuperseded Adoption. A legitimate update arrives as a NEW Adoption + Supersession, which re-pins.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  req    jsonb := p_payload->'req';
  res    jsonb;
  v_proj text := ckp._project();
  v_idk  text := COALESCE(current_setting('ckp.identity_key', true), 'pgck-localhost');
  v_canon  text;   -- CI-B-2: canonical instance.* name (registry lookup key)
  v_aff    jsonb;  -- CI-B-1: the sealed affordance row (the registry IS the routing authority)
  v_legacy text;   -- CI-B-2: the legacy handler name (alias window)
BEGIN
  PERFORM set_config('ckp.project', v_proj, false);
  PERFORM set_config('ckp.identity_key', v_idk, false);

  -- CI-B-1/B-2 — the sealed registry is the SOLE routing authority. Resolve the canonical
  -- name + its sealed affordance row; an unregistered verb fails typed (unknown_affordance)
  -- with zero payload evaluation (no fallthrough); a delegate=true row is the Tier-2 tool
  -- seam; governance-plane verbs never execute here (proposal/vote/apply — CI-D). Otherwise
  -- resolve the legacy handler name (alias window) so the CASE below is unchanged and v0.3.0
  -- web2 keeps working.
  v_canon := ckp.verb_canon(p_verb);
  -- Resolve against the CALLING project, not a fixed kernel. This asked
  -- registry_lookup('pgck', ...) for every caller, so a verb registered by any
  -- other kernel was invisible and every non-pgck workspace got
  -- unknown_affordance. It looked correct only because the seed and the
  -- registrars were hard-coded to the same literal -- writer and reader wrong
  -- in the same direction. (smoke-s4 s41: registered under 's41-test',
  -- resolved under 'pgck'.)
  v_aff   := ckp.registry_lookup(v_proj, v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable',
      'plane', 'governance', 'verb', p_verb, 'canonical', v_canon)
      || jsonb_build_object('req', req);
  -- Tier 2 (3/3b): a governed query affordance (SPARQL text sealed via the governance plane,
  -- compiled into ckp.plans at apply) routes here. The caller binds typed params only; the query
  -- text is the kernel's OWN sealed fact, never caller input.
  ELSIF v_aff->>'plane' = 'query' THEN
    RETURN ckp.run_query_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  -- Scoring-loop layer 3: a governed DERIVED-read affordance ({formula, scope} sealed via the
  -- governance plane, compiled into ckp.plans at apply) routes here. The caller binds only the
  -- concept; the formula is the kernel's OWN sealed fact. Returns the band-less {ok, value,
  -- scored, freshness} envelope — the role-floor-reachable read surface the scoring client calls.
  ELSIF v_aff->>'plane' = 'derived' THEN
    RETURN ckp.run_derived_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  END IF;
  -- CI-E-5: instance.query is the typed derived-QueryShape read (the legacy instances.list alias
  -- keeps its list behavior below — routed by the ORIGINAL verb, not the shared canonical).
  IF p_verb = 'instance.query' THEN
    RETURN ckp.query(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.reach' THEN
    RETURN ckp.reach(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.transition' THEN
    RETURN ckp.transition(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.snapshot' THEN
    RETURN ckp.snapshot(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'concept.match' THEN
    RETURN ckp.concept_match(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.explain' THEN
    RETURN ckp.explain(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.retire' THEN
    RETURN ckp.retire(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.validate' THEN
    RETURN ckp.validate_instance(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 (v0.4.4): generic typed create. A uniform {type:<class IRI>, …fields} body
  -- routes to the §4 generic path, which seals it against the kernel's OWN declared shape.
  -- The discriminator is a TOP-LEVEL `type`: the legacy concretion forms carry no top-level
  -- `type` (task.create -> {task:{…}}, kernel.create -> {name:…}). `name` is NOT a usable
  -- discriminator here — it is a perfectly ordinary property on a generic type — so a `{task}`
  -- body still wins (the established concretion path) but everything else with a `type` is generic.
  -- 0.4.51: `@type` and a nested `{body:{type}}` route here TOO, so the teaching
  -- refusal is reachable. Without this a caller following JSON-LD habit fell
  -- through to the task.create concretion and was told "kernel and title
  -- required" — an error about a verb it did not call, naming fields it never
  -- heard of. create_typed answers `type_not_readable_here` and names the two
  -- shapes that ARE read. Routing on a key it will then refuse is deliberate:
  -- the alternative is a correct-looking error from the wrong handler, which is
  -- the class of misdirection F9 filed.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type' OR p_payload ? '@type'
             OR (p_payload ? 'body' AND ((p_payload->'body') ? 'type' OR (p_payload->'body') ? '@type')))
        AND NOT (p_payload ? 'task') THEN
    RETURN ckp.create_typed(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 / v0.5 T4: generic typed update. instance.update with a `patch` sub-object patches
  -- by the type's declared properties (re-sealed); the legacy flat {id,…fields} form falls
  -- through to verb_to_legacy -> task.update.
  ELSIF p_verb = 'instance.update' AND (p_payload ? 'patch') THEN
    RETURN ckp.update_typed(p_payload) || jsonb_build_object('req', req);
  END IF;
  v_legacy := ckp.verb_to_legacy(p_verb, p_payload);

  CASE v_legacy

  -- ---- generic URN-addressed instance ops (the main goal) --------------
  WHEN 'instances.list', 'instances.last', 'instances.count', 'instance.get' THEN
    res := ckp._query(v_legacy, p_payload);

  -- ---- discovery -------------------------------------------------------
  -- B4: the surface in force, checked against the digests its epoch sealed.
  -- A READ, never a gate — a false positive here would take the substrate down,
  -- and legitimate drift exists. Findings name what was measured; empty = pass.
  WHEN 'surface.check' THEN
    res := ckp.surface_check(v_proj);

  -- B3: the store-level G-1 audit — the cross-node integrity body locality puts
  -- beyond the instance gate (§4.5). B1a: authority resolved by traversal, with
  -- an empty chain reported AS empty (persona spec §3).
  WHEN 'integrity.check' THEN
    res := ckp.integrity_check(v_proj);

  WHEN 'authority.mine' THEN
    res := ckp.authority_of(NULL);

  -- 0.4.51 — THE CHECKER SURFACE. Every one of these answered a question this
  -- kernel had to answer with a hand-written psql probe in PASS-30, which is a
  -- second surface by definition: a check that lives in someone's scratch
  -- directory cannot be re-run by the party who needs it, and it is not a fact.
  -- As governed verbs they are callable by any identity the kernel grants,
  -- their answers are attributable, and the negative control ships WITH the
  -- gate instead of beside it.
  WHEN 'wave.signals' THEN
    res := ckp.wave_signals(p_payload);

  -- one-version alias (0.4.63): routes, answers, and says where to go. Removed
  -- next release — nothing tagged ever carried the old name.
  WHEN 'wave.oracle' THEN
    res := ckp.wave_signals(p_payload)
        || jsonb_build_object('deprecated', 'wave.oracle is wave.signals; this alias is removed next release');

  WHEN 'adoption.check' THEN
    res := ckp.adoption_check(p_payload);

  WHEN 'wave.project' THEN
    res := ckp.wave_project_spine(p_payload);

  WHEN 'surface.typecheck' THEN
    res := ckp.surface_typecheck(p_payload, v_proj);

  WHEN 'surface.unshaped' THEN
    res := ckp.surface_unshaped(v_proj);

  WHEN 'surface.declared' THEN
    res := ckp.surface_declared(p_payload, v_proj);

  WHEN 'surface.grounding' THEN
    res := ckp.surface_grounding(p_payload, v_proj);

  WHEN 'project.resolve' THEN
    res := ckp.project_resolve(p_payload);

  WHEN 'affordances' THEN
    -- B1 (pgCK#56): derived from SEALED ckp:Affordance instances of THIS kernel,
    -- carrying inShape resolved into a real input contract, retirement honoured,
    -- and the registry/sealed drift reported under `unsealed` rather than merged.
    -- Was: an unfiltered SPARQL scan of a graph nobody writes, which returned []
    -- for a substrate holding sealed affordances — reads as "no grants", means
    -- "nothing declared".
    res := ckp.affordances_of(v_proj);

  WHEN 'kernels.list' THEN
    res := jsonb_build_object('ok', true, 'kernels', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', COALESCE(body->>RL, regexp_replace(id,'^backlog:','')),
        'id', id, 'urn', 'ckp://Kernel#'||ckp._slug(COALESCE(body->>RL, regexp_replace(id,'^backlog:','')))) ORDER BY id)
      FROM ckp.instances WHERE body->>'type' = N||'Goal' AND id LIKE 'backlog:%'), '[]'::jsonb));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      -- 0.4.66: proofs are PLURAL since obligations (0.4.65). `proof` stays the
      -- byte-proof (the hmac row — what `verified` checks) so existing readers
      -- keep their meaning; `proofs` carries EVERY row, obligations included —
      -- "which agreed checks did this seal pass" must be readable at the door,
      -- or the obligation mark exists only for parties with table access.
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid AND method='hmac+sha256' ORDER BY id DESC LIMIT 1),
        'proofs', COALESCE((SELECT jsonb_agg(jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) ORDER BY id) FROM ckp.proof WHERE about=tid),'[]'::jsonb),
        'ledger', COALESCE((SELECT jsonb_agg(jsonb_build_object('seq',seq,'prev_seq',prev_seq,'body_sha256',body_sha256,'ts',ts) ORDER BY seq) FROM ckp.ledger WHERE instance_id=tid),'[]'::jsonb));
    END;

  WHEN 'instance.verify' THEN
    res := jsonb_build_object('ok', true, 'id', p_payload->>'id', 'verified', ckp.verify(p_payload->>'id'));

  -- ---- participant input (kernel governs by sealing) -------------------
  WHEN 'participant.join' THEN
    res := jsonb_build_object('ok', true, 'sub', p_payload->>'name',
      'urn', 'urn:ckp:participant:'||ckp._slug(p_payload->>'name'));

  -- 0.4.43: germination as a GOVERNED act. kernel.create seals a board Goal and
  -- creates no kernel; the pgRDF route creates a correct kernel that belongs to
  -- nobody. This is the one that does both: client declares structure, substrate
  -- stamps ckp:ownedBy from the verified connection.
  WHEN 'kernel.germinate' THEN
    res := ckp.germinate_kernel(
             COALESCE(p_payload->>'project', p_payload->>'name'),
             p_payload->>'label',
             COALESCE(p_payload->>'projectKind', 'personal'));

  WHEN 'kernel.create' THEN
    DECLARE nm text := p_payload->>'name'; gid text;
    BEGIN
      IF nm IS NULL OR btrim(nm)='' THEN res := jsonb_build_object('ok',false,'error','kernel name required');
      ELSE
        gid := 'backlog:'||nm;
        PERFORM ckp.seal(gid, jsonb_build_object('type', N||'Goal', '@id', 'ckp://Goal#'||gid, N||'goal_id', gid,
          RL, nm, N||'title', nm, N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        res := jsonb_build_object('ok',true,'kernel',nm,'id',gid);
      END IF;
    END;

  WHEN 'task.create' THEN
    DECLARE t jsonb := p_payload->'task'; k text := p_payload->'task'->>'target_kernel';
            -- F-A (pgCK#9/#10): identity is SERVER-DERIVED from the verified connection
            -- (the ckp.requester GUC the trusted ingress sets from the NATS-verified bearer),
            -- NEVER the client payload. A payload {sub} is ignored — it cannot forge created_by.
            sub text := current_setting('ckp.requester', true); tid text; qseq int; v_body jsonb;
    BEGIN
      IF k IS NULL OR (p_payload->'task'->>'title') IS NULL THEN
        res := jsonb_build_object('ok',false,'error','kernel and title required');
      ELSE
        SELECT COALESCE(MAX((i.body->>(N||'queue_seq'))::int),0)+1 INTO qseq
          FROM ckp.instances i WHERE i.body->>(N||'target_kernel')=k AND i.body->>'type'=N||'Task';
        tid := 'task-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        v_body := jsonb_build_object('type', N||'Task', '@id', 'ckp://Task#'||tid, N||'task_id', tid,
          N||'title', t->>'title', N||'part_of_goal', 'backlog:'||k, N||'target_kernel', k,
          N||'lifecycle_state', COALESCE(t->>'lifecycle_state','planned'),
          N||'priority', COALESCE(t->'priority','5'::jsonb), N||'queue_seq', to_jsonb(qseq),
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN
          v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub),
                                             'participant', jsonb_build_object('sub', sub));
        END IF;
        PERFORM ckp.seal(tid, v_body);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  WHEN 'task.update' THEN
    DECLARE tid text := p_payload->>'id'; cur jsonb; v_fld text;
    BEGIN
      SELECT body INTO cur FROM ckp.instances WHERE id=tid;
      IF cur IS NULL THEN res := jsonb_build_object('ok',false,'error','instance not found');
      ELSE
        cur := cur - 'participant';
        -- Apply EVERY patchable task field the caller sent (closed allow-list = the task
        -- model's mutable properties; never arbitrary keys), preserving JSON type with ->
        -- not ->> so a number stays a number end-to-end. Pre-0.4.3 this hardcoded only
        -- lifecycle_state + priority — it silently dropped title (CK.Lib.Js report 2.1) and
        -- ->> coerced priority 1 → "1" (report 2.2).
        FOREACH v_fld IN ARRAY ARRAY['title','priority','lifecycle_state','part_of_goal','target_kernel'] LOOP
          IF p_payload ? v_fld THEN
            cur := cur || jsonb_build_object(N||v_fld, p_payload->v_fld);
          END IF;
        END LOOP;
        PERFORM ckp.seal(tid, cur);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- board snapshot (web protocol verb the browser surfaces use) -------
  WHEN 'snapshot.board' THEN
    res := jsonb_build_object('ok', true,
      'kernels', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', i.body->>(N||'title'), 'id', i.id)
                    ORDER BY i.body->>(N||'title')), '[]'::jsonb)
                  FROM ckp.instances i WHERE i.body->>'type' = N||'Goal'),
      'tasks', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', i.id,
                  'title', i.body->>(N||'title'),
                  'target_kernel', i.body->>(N||'target_kernel'),
                  'part_of_goal', i.body->>(N||'part_of_goal'),
                  'lifecycle_state', i.body->>(N||'lifecycle_state'),
                  'priority', i.body->(N||'priority'),
                  'queue_seq', i.body->(N||'queue_seq'),
                  'created_by', i.body->>(N||'created_by'),
                  'proof_digest', (SELECT p.digest FROM ckp.proof p WHERE p.about = i.id ORDER BY p.id DESC LIMIT 1),
                  'verified', ckp.verify(i.id))
                  ORDER BY i.body->>(N||'target_kernel'), NULLIF(i.body->>(N||'queue_seq'),'')::int), '[]'::jsonb)
                FROM ckp.instances i WHERE i.body->>'type' = N||'Task'));

  -- ---- raw instance bodies — bulk replay for CKHexStore + corpus capture ---
  -- returns the literal IRI-keyed JSON-LD bodies (with @id + type), the shape a
  -- browser quad store ingests and a fixture corpus records (SPEC.CK.HEXSTORE Q4).
  WHEN 'snapshot.bodies' THEN
    DECLARE k text := p_payload->>'kernel';
    BEGIN
      res := jsonb_build_object('ok', true,
        'bodies', (SELECT coalesce(jsonb_agg(i.body ORDER BY i.id), '[]'::jsonb)
                   FROM ckp.instances i
                   WHERE k IS NULL OR i.body->>(N||'target_kernel') = k));
    END;

  -- ---- concept link (Edge) — captured so the structure is recoverable ---
  -- 0.4.51 — THE EDGE CLASS IS THE CALLER'S TO NAME, AND WAS A DEFAULT NOTHING
  -- DECLARED. This sealed N||'Edge' = urn:ckp:board/Edge unconditionally. That
  -- class is declared in ONE file, examples/example.kernel.ttl, which no module
  -- can load (import_module knows {task, goal}), so the path COULD NOT SEAL FOR
  -- ANY PARTICIPANT ON ANY KERNEL SURFACE, regardless of grants — measured by
  -- pgCK.MCP as F6 and re-measured here: SELECT ?g ?p WHERE { GRAPH ?g { ?s ?p
  -- <urn:ckp:board/Edge> } } returns ZERO ROWS fleet-wide.
  --
  -- Worse, 0.4.42's own comment in ckp._type_admitted asserted the exit
  -- condition was met — "urn:ckp:board/{Task,Goal,Edge,Message} now carry shapes
  -- in the project kernel graph". They do not. That sentence is deleted with
  -- this default; a comment claiming a gate is a claim, and R1 applies to
  -- claims about our own code exactly as it applies to shapes.
  --
  -- The kernel declares what an edge IS; the substrate refuses what violates
  -- that. So the class comes from the caller and the property IRIs follow ITS
  -- namespace — the same rule create_typed's fallback already uses. A caller
  -- that names no class is REFUSED with the reason, never sealed under a class
  -- nobody declared.
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_etype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_ens   text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF v_etype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','edge_type_required',
          'hint','instance.link requires {type}: the edge class THIS kernel declares (sh:targetClass or a declared rdfs:Class/owl:Class in its composed surface). There is no substrate default — the former one, urn:ckp:board/Edge, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_etype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','instance.link {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Edge');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        v_ens := regexp_replace(v_etype, '[^/#]*$', '');    -- the declared class's namespace
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', v_etype, '@id', 'ckp://Edge#'||eid,
          v_ens||'source', src, v_ens||'predicate', pred, v_ens||'target', tgt, v_ens||'topic', topic,
          v_ens||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'type',v_etype,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  -- 0.4.51 — the SAME defect as edge.create, one class along, and untested by
  -- the party who found the first: this sealed N||'Message' = urn:ckp:board/
  -- Message, declared by no loadable module, so notify could not seal either.
  -- The class is the caller's to name; the property IRIs follow its namespace.
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := COALESCE(p_payload->>'predicate','notifies');
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
            v_mtype text := NULLIF(btrim(COALESCE(p_payload->>'type','')), '');
            v_mns   text;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSIF v_mtype IS NULL THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','message_type_required',
          'hint','notify requires {type}: the message class THIS kernel declares. There is no substrate default — the former one, urn:ckp:board/Message, is declared by no loadable module and could never seal.');
      ELSIF position(':' in v_mtype) = 0 THEN
        res := jsonb_build_object('ok',false,'refused',true,'error','type_must_be_iri',
          'hint','notify {type} must be the full class IRI, e.g. urn:ckp:<project>/type/Message');
      ELSE
        v_mns := regexp_replace(v_mtype, '[^/#]*$', '');
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', v_mtype, '@id', 'ckp://Message#'||mid,
          v_mns||'from', frm, v_mns||'to', tgt, v_mns||'predicate', pred, v_mns||'body', bdy, v_mns||'topic', topic,
          v_mns||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(v_mns||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'type',v_mtype,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._structural_digest(p_graph bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- 0.4.67 — THE STRUCTURAL PLANE (§5b alignment, finding-1786862028710113000).
--
-- _surface_digest is the COPY plane: sha256 over rendered lines with blank-node
-- LABELS included, so it moves on every reload and no third party can recompute
-- it from published files. This is the plane that survives: each blank node is
-- replaced by a signature over its own incident triples (itself marked _:a,
-- every other blank node flattened to _:z), so the digest depends on the shape
-- a node sits in and never on the label it happened to receive.
--
-- THE ALGORITHM IS THE FLEET'S, byte-for-byte (pgrdf_fingerprint):
--   ground     = sorted lines with no blank node, joined by \n, sha256
--   sig(b)     = sha256 of b's incident lines (self→_:a, other→_:z), sorted
--   bnode      = sha256 of the sorted signature hexes, joined by \n
--   structural = sha256( ground_text || '\n--\n' || signature_hexes )
-- ACCEPTANCE, measured 2026-08-16: three independent loads of the v3.11 core
-- (bench urn:ckp:core, bench urn:ckp:core/v3.11, test-rig urn:ckp:core) carry
-- three different byte digests and ONE structural digest, 9a791c6c3d6d07cb… —
-- reproduced by this function against the client-side tool's published pins.
--
-- HONEST LIMITS, never to be flattened: this is FIRST-DEGREE hashing, not
-- RDFC-1.0 — equal digests are strong evidence of isomorphism, NOT proof
-- (symmetric blank-node structures can collide); unequal digests ARE proof of
-- difference. ASSERTED ONLY — inferred triples re-derive and are a check
-- value, never content.
--
-- INTERIM SEAT: reads the engine's quad/dictionary tables directly because the
-- public SPARQL surface cannot exclude inferred triples. The coupling is pinned
-- by the co-shipped bundle and fails LOUD on schema drift; pgRDF#117
-- (pgrdf.graph_digest, RDFC-1.0) retires this function's body.
DECLARE
  v_ground text;
  v_sigs   text;
BEGIN
  IF to_regclass('pgrdf._pgrdf_quads') IS NULL OR to_regclass('pgrdf._pgrdf_dictionary') IS NULL THEN
    RAISE EXCEPTION 'ckp._structural_digest: the engine''s quad/dictionary tables are not where the pinned bundle put them — refusing rather than inventing a digest (interim seat; pgRDF#117 is the lasting one)';
  END IF;
  WITH t AS (
    SELECT x.subject_id sid, x.object_id oid, s.term_type st, o.term_type ot,
      CASE s.term_type WHEN 1 THEN '<'||s.lexical_value||'>' WHEN 2 THEN '_:'||s.lexical_value
        ELSE '"'||replace(replace(s.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"')||'"' END AS sr,
      CASE p.term_type WHEN 1 THEN '<'||p.lexical_value||'>' WHEN 2 THEN '_:'||p.lexical_value
        ELSE '"'||replace(replace(p.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"')||'"' END AS pr,
      CASE o.term_type WHEN 1 THEN '<'||o.lexical_value||'>' WHEN 2 THEN '_:'||o.lexical_value
        ELSE '"'||replace(replace(replace(o.lexical_value, chr(92), chr(92)||chr(92)), '"', chr(92)||'"'), chr(10), chr(92)||'n')||'"'
          || coalesce('@'||o.language_tag,
               CASE WHEN dt.lexical_value IS NOT NULL AND dt.lexical_value <> 'http://www.w3.org/2001/XMLSchema#string'
                    THEN '^^<'||dt.lexical_value||'>' END, '') END AS orr
    FROM pgrdf._pgrdf_quads x
    JOIN pgrdf._pgrdf_dictionary s ON s.id = x.subject_id
    JOIN pgrdf._pgrdf_dictionary p ON p.id = x.predicate_id
    JOIN pgrdf._pgrdf_dictionary o ON o.id = x.object_id
    LEFT JOIN pgrdf._pgrdf_dictionary dt ON dt.id = o.datatype_iri_id
    WHERE x.graph_id = p_graph AND NOT x.is_inferred
  ),
  ground AS (
    SELECT string_agg(sr||' '||pr||' '||orr||' .', E'\n' ORDER BY (sr||' '||pr||' '||orr||' .') COLLATE "C") AS g
    FROM t WHERE st <> 2 AND ot <> 2
  ),
  bnodes AS (
    SELECT DISTINCT sid AS b FROM t WHERE st = 2
    UNION SELECT DISTINCT oid FROM t WHERE ot = 2
  ),
  incident AS (
    SELECT b.b,
      CASE WHEN t.st=2 THEN CASE WHEN t.sid=b.b THEN '_:a' ELSE '_:z' END ELSE t.sr END
      ||' '||t.pr||' '||
      CASE WHEN t.ot=2 THEN CASE WHEN t.oid=b.b THEN '_:a' ELSE '_:z' END ELSE t.orr END
      ||' .' AS nline
    FROM bnodes b JOIN t ON (t.st=2 AND t.sid=b.b) OR (t.ot=2 AND t.oid=b.b)
  ),
  sigs AS (
    SELECT encode(digest(convert_to(string_agg(nline, E'\n' ORDER BY nline COLLATE "C"),'UTF8'),'sha256'),'hex') AS sig
    FROM incident GROUP BY b
  )
  SELECT COALESCE((SELECT g FROM ground), ''),
         COALESCE((SELECT string_agg(sig, E'\n' ORDER BY sig COLLATE "C") FROM sigs), '')
    INTO v_ground, v_sigs;
  RETURN encode(digest(convert_to(v_ground||E'\n--\n'||v_sigs, 'UTF8'), 'sha256'), 'hex');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_grounding(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_iris text[];
  v_iri  text;
  v_g    bigint;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  -- an explicit {iri} examines ONE graph (the brought-graph admission read);
  -- with no payload the kernel's whole ground is censused.
  IF COALESCE(btrim(p_payload->>'iri'),'') <> '' THEN
    v_iris := ARRAY[p_payload->>'iri'];
  ELSE
    v_iris := ARRAY[format('urn:ckp:%s/shapes/composed', v_proj),
                    format('urn:ckp:%s/kernel/ck', v_proj)]
              || ckp._adopted_graphs(v_proj);
  END IF;
  FOREACH v_iri IN ARRAY v_iris LOOP
    v_g := pgrdf.add_graph(v_iri);
    v_rows := v_rows || (
      SELECT jsonb_build_object(
        'iri', v_iri,
        'asserted',        count(*),
        'groundTriples',   count(*) FILTER (WHERE s.term_type <> 2 AND o.term_type <> 2),
        'bnodeTriples',    count(*) FILTER (WHERE s.term_type = 2 OR o.term_type = 2),
        'distinctBnodes',  (SELECT count(DISTINCT d) FROM (
                              SELECT q2.subject_id d FROM pgrdf._pgrdf_quads q2
                                JOIN pgrdf._pgrdf_dictionary s2 ON s2.id = q2.subject_id
                               WHERE q2.graph_id = v_g AND NOT q2.is_inferred AND s2.term_type = 2
                              UNION
                              SELECT q3.object_id FROM pgrdf._pgrdf_quads q3
                                JOIN pgrdf._pgrdf_dictionary o3 ON o3.id = q3.object_id
                               WHERE q3.graph_id = v_g AND NOT q3.is_inferred AND o3.term_type = 2) u),
        'copyDigest',       ckp._surface_digest(v_g),
        'structuralDigest', ckp._structural_digest(v_g),
        'nodeshapes', (SELECT count(*) FROM pgrdf.sparql(format(
          'SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/shacl#NodeShape> } }', v_iri))),
        'properties', (SELECT count(*) FROM pgrdf.sparql(format(
          'SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/ns/shacl#path> ?p } }', v_iri))))
      FROM pgrdf._pgrdf_quads q
      JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
      JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
      WHERE q.graph_id = v_g AND NOT q.is_inferred);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj, 'graphs', v_rows,
    'planes', 'FILE digests pin published bytes (verify with shasum against the sidecar). copyDigest pins THIS store''s bytes and moves on every reload — in-store drift detection only, never cross-bench identity. structuralDigest survives reload (first-degree blank-node signatures, the fleet algorithm) — what a third party recomputes from the published modules. Counts are the blank-node-immune instrument: 42 NodeShapes = 27 core + 11 wave + 4 lexicon on a fully-adopted kernel.',
    'verdictAsymmetry', 'unequal structural digests PROVE two graphs differ; equal ones are strong evidence of isomorphism and NOT proof (not RDFC-1.0). Never upgrade ISOMORPHIC_LIKELY to identical.');
END;
$function$
;

-- the upgrade path's half of the registry seed (fresh installs get it from the
-- baseline's seed block) and the pin-table columns for stores that walked the
-- 0.4.61 line before the structural plane existed. NULL structural fields on a
-- pre-existing pin mean "pinned before the plane existed" — adoption.check
-- reports them honestly; they backfill at the next fresh composition.
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS structural_digest TEXT;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS nodeshapes INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS properties INTEGER;
ALTER TABLE ckp.adoption_pins ADD COLUMN IF NOT EXISTS asserted INTEGER;
INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane)
VALUES ('pgck','surface.grounding','input.kernel.pgck.action.surface.grounding','instance')
ON CONFLICT (kernel, verb) DO NOTHING;
-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
