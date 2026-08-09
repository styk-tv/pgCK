-- pgck 0.4.32 -> 0.4.33 — #59: persist the stamps the gate validated.
--
-- pgCK#41 derived the four ckp:InstanceShape-required properties (producedBy,
-- createdBy, sealedAtEpoch, conformsToShape) INTO the candidate ckp.seal
-- validates. It did not put them in the STORE. seal composed
--   v_cand := _body_to_ttl(p_body) || _parent_closure_ttl() || _derived_stamp_ttl()
-- validated that, and then stored the raw p_body and HMAC'd the raw p_body. The
-- stamps lived only in a transient string. Three consequences, all measured at
-- 0.4.32 and filed as #59:
--
--   1. Provenance is not durably recoverable. A reader of a sealed instance
--      cannot answer who made it, at which epoch, under which shape — which
--      SPEC.CKP v3.11 §4.3 names as the difference between a record and
--      provable work.
--   2. Stored rows carry none of the four, so a store-level re-validation of
--      "every ckp:Instance has createdBy" is vacuous: it passes because the
--      rows are targeted by nothing.
--   3. The proof chain does not cover the provenance. The HMAC is over the raw
--      body, so the attestation says "this body was sealed", never "by this
--      participant, under this shape". Integrity without attribution.
--
-- THE FIX IS ONE DERIVATION WITH TWO RENDERINGS, and that is the point rather
-- than an implementation detail. Deriving the stamps twice — once as Turtle for
-- the gate, once as JSON for the store — is the two-registries defect class
-- this substrate has already shipped twice (the affordance registry vs the
-- dispatch CASE, #56). Two producers of "the same" four values drift, and the
-- drift is invisible because each side validates alone. So:
--
--   ckp._derived_stamps()    the ONLY place the four are computed -> jsonb
--   ckp._stamps_to_ttl()     renders that jsonb as the gate's Turtle
--   ckp._derived_stamp_ttl() unchanged signature, now the composition of the
--                            two, so every existing caller keeps working and
--                            cannot obtain a different answer
--
-- ckp.seal then derives ONCE, validates the Turtle rendering, and — only after
-- the gate passes — merges the SAME jsonb into p_body BEFORE the digest. So
-- v_sha, the HMAC, the stored row and ckp.verify()'s recompute all cover the
-- provenance, and "what is checked is what is stamped" becomes true of the
-- store and not only of the candidate.
--
-- AND A DENIAL VECTOR CLOSED ON THE WAY. All four properties are maxCount 1 in
-- ckp:InstanceShape. A caller-supplied "createdBy" in the body was projected
-- into the candidate by _body_to_ttl while _derived_stamp_ttl added the real
-- one — two values, MaxCountConstraintComponent, seal refused. Any client could
-- make its own seal fail by naming a property it is not allowed to assert, and
-- the failure read as a shape defect rather than a rejected claim. The four
-- keys are now STRIPPED from the caller body before the candidate is composed:
-- claim-ignoring done structurally, per §4.3, instead of by a caller convention.
--
-- STORED-BODY SHAPE CHANGES FOR NEW SEALS. Not retroactive: existing rows are
-- untouched and keep verifying against their own digests. A seal after this
-- migration stores four more properties and therefore a different digest than
-- the same body would have produced before it. That is the intended semantics —
-- the digest now covers the provenance — and it is why this rides its own
-- version rather than a patch.
--
-- SCOPE, STATED SO IT IS NOT OVERREAD. This closes #59 points 1 and 3 fully.
-- Point 2 becomes possible rather than done: stored rows now carry the four,
-- but the parent-closure typing that makes InstanceShape TARGET them is still
-- derived at gate time from the composed graph, not stored on the row. A
-- store-level G-1 audit must compose the closure the same way the gate does.
-- That auditor is a governed verification affordance (§4.5) and is not this
-- migration. Nothing here claims the audit is enforced.
--
-- bench: B2 | destroys: nothing (new seals only)

-- ---------------------------------------------------------------------------
-- The one derivation.
-- ---------------------------------------------------------------------------
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

  -- producedBy — the kernel that processed this instance. Server-derived.
  v_out := v_out || jsonb_build_object(N||'producedBy', 'urn:ckp:'||p_project||'/kernel/ck');

  -- createdBy — the resolved participant. Never from the payload; the caller's
  -- own claim was stripped before this ran.
  IF p_participant IS NOT NULL THEN
    v_out := v_out || jsonb_build_object(N||'createdBy', p_participant);
  END IF;

  -- sealedAtEpoch — the producing kernel's epoch at seal. Carried as a JSON
  -- number so a re-projection of the stored body yields xsd:integer, which is
  -- what InstanceShape declares.
  SELECT epoch INTO v_ep FROM ckp.kernel_epoch WHERE kernel = p_project;
  v_out := v_out || jsonb_build_object(N||'sealedAtEpoch', to_jsonb(COALESCE(v_ep,0)));

  -- conformsToShape — the declared shape targeting this type, resolved from the
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

-- ---------------------------------------------------------------------------
-- Rendering 1 — the gate's Turtle. Byte-identical to what 0.4.28 emitted:
-- same four triples, same order, same bare-integer form for sealedAtEpoch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp._stamps_to_ttl(p_subj text, p_stamps jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N     text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_ttl text := '';
BEGIN
  IF p_subj IS NULL OR p_stamps IS NULL OR p_stamps = '{}'::jsonb THEN RETURN ''; END IF;

  IF p_stamps ? (N||'producedBy') THEN
    v_ttl := v_ttl || '<'||p_subj||'> <'||N||'producedBy> <'||(p_stamps->>(N||'producedBy'))||'> .'||chr(10);
  END IF;
  IF p_stamps ? (N||'createdBy') THEN
    v_ttl := v_ttl || '<'||p_subj||'> <'||N||'createdBy> <'||(p_stamps->>(N||'createdBy'))||'> .'||chr(10);
  END IF;
  IF p_stamps ? (N||'sealedAtEpoch') THEN
    v_ttl := v_ttl || '<'||p_subj||'> <'||N||'sealedAtEpoch> '||(p_stamps->>(N||'sealedAtEpoch'))||' .'||chr(10);
  END IF;
  IF p_stamps ? (N||'conformsToShape') THEN
    v_ttl := v_ttl || '<'||p_subj||'> <'||N||'conformsToShape> <'||(p_stamps->>(N||'conformsToShape'))||'> .'||chr(10);
  END IF;
  RETURN v_ttl;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- Compatibility wrapper — same signature as 0.4.28, now unable to disagree
-- with the store because both go through _derived_stamps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp._derived_stamp_ttl(p_subj text, p_type text, p_project text, p_participant text, p_shapes_graph integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN ckp._stamps_to_ttl(
    p_subj,
    ckp._derived_stamps(p_subj, p_type, p_project, p_participant, p_shapes_graph));
END;
$function$
;

-- ---------------------------------------------------------------------------
-- The seal. Two changes, both in the marked blocks; everything else is 0.4.30
-- verbatim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp.seal(p_instance_id text, p_body jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N        TEXT := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_core   INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_kgraph INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
  v_identity_key TEXT := COALESCE(
    NULLIF(current_setting('ckp.identity_key', true), ''),
    (SELECT v FROM ckp.config WHERE k='identity_key')
  );
  v_project TEXT := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_type   TEXT := p_body->>'type';
  v_missing TEXT;
  v_sha    TEXT;
  v_sig    TEXT;
  v_prev   BIGINT;
  v_now    TIMESTAMPTZ := now();
  v_led_ttl TEXT;
  v_prf_ttl TEXT;
  v_sub    TEXT;
  v_display TEXT;
  v_email  TEXT;
  v_participant TEXT;
  v_stamps JSONB := '{}'::jsonb;
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
  v_sub     := p_body->'participant'->>'sub';
  v_display := NULLIF(trim(COALESCE(p_body->'participant'->>'preferred_username','')), '');
  v_email   := NULLIF(trim(COALESCE(p_body->'participant'->>'email','')), '');
  IF p_body ? 'participant' AND v_sub IS NOT NULL AND length(trim(v_sub)) > 0 THEN
    v_participant := 'urn:ckp:participant:' || ckp.urn_normalise(v_sub);
  ELSE
    v_participant := 'urn:ckp:participant:anon:' || gen_random_uuid()::text;
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

  -- 5. PROJECT link triples for Task/Goal instances into the project board graph (CKB-5).
  PERFORM ckp.project_links(v_project, p_instance_id, p_body);

  RETURN v_sha;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- Ring floor. The completeness pass runs only at CREATE EXTENSION, so an
-- upgrade that adds functions leaves them owned by the calling superuser with
-- default PUBLIC EXECUTE, while a fresh install has them owned by ck_substrate
-- — same extversion, different catalogs, which is the divergence the two-route
-- byte-identical check exists to catch. Re-assert it here, as 0.4.31 did.
-- ---------------------------------------------------------------------------
DO $floor_0433$
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
$floor_0433$;

-- The two new internals are substrate-only, exactly as _derived_stamp_ttl has
-- been since 0.4.28: ck_participant reaches the seal through ckp.dispatch and
-- never these.
REVOKE ALL ON FUNCTION ckp._derived_stamps(text,text,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._derived_stamps(text,text,text,text,integer) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._derived_stamps(text,text,text,text,integer) TO ck_substrate;

REVOKE ALL ON FUNCTION ckp._stamps_to_ttl(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._stamps_to_ttl(text,jsonb) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._stamps_to_ttl(text,jsonb) TO ck_substrate;

REVOKE ALL ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._derived_stamp_ttl(text,text,text,text,integer) TO ck_substrate;

CALL ckp._enforce_internal_floor();
