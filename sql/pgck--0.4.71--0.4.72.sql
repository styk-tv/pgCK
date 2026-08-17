-- pgck 0.4.71 → 0.4.72 — GUIDANCE AS VALIDATION, AND ITS RATCHET
--
-- The operator's design, measured feasible and shipped whole: "if you adopt
-- core, valid core looks like this — you get warnings. Adopt the rule NO
-- WARNINGS ON SEAL and now they are law: comply, or others cannot rely on
-- what you do."
--
--   severity gate      seal refuses on sh:Violation (and absent severity —
--                      SHACL's default, so NOTHING pre-existing weakens);
--                      sh:Warning/sh:Info results SEAL AND SURFACE in the
--                      reply's `warnings` via a txn-local GUC. validate gains
--                      the same partition (fourth validate⟺seal axis — a
--                      dry-run must not predict a refusal the seal won't make).
--   no-warnings        the ratchet as a proof obligation: kernels that adopt
--                      it turn the guidance band into refusals, and every
--                      conforming seal carries obligation:no-warnings — the
--                      warranty rides the fact; reliance is a row, not a
--                      reputation.
--   adopts-resolves    referential validity of Adoptions (module-IRI-is-
--                      graph-IRI): a graph-less adopts refuses — the class
--                      paid for five times, latest hours ago.
--   structural-pin     the graph being adopted is structurally the graph
--                      first pinned under that IRI — swap-under-a-pinned-name
--                      refuses; reload relabelling cannot fool this plane.
--   fleet.adoptions    the cross-kernel adoption matrix as a verb, malformed
--                      references flagged mechanically — the census that
--                      caught ontosys by hand, re-runnable by anyone.
--   surface.explain    the shape teaches its PROSE: class + per-property
--                      rdfs:comment through the door (SAH3000's lesson — a
--                      teaching reachable only by hand SPARQL is a check that
--                      is not a verb). A declared-but-untaught property shows
--                      its null honestly.
--   adoption.check     the why-text separates row-state from engine-
--                      capability (0.4.71's live wording defect).
--
-- Changed: seal, validate_instance, create_typed, update_typed,
-- register_proof_obligation, _run_proof_obligations, adoption_check, dispatch.
-- New: _oblig_adopts_resolves, _oblig_structural_pin, _oblig_no_warnings,
-- fleet_adoptions, surface_explain, + two registry rows (footer).
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

CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);
  v_type    text := v_body->>'type';
  v_proj    text := ckp._project();
  v_subj    text := 'urn:ckp:validate:'||pg_backend_pid();
  v_ns      text;
  v_propmap jsonb;
  v_resolved jsonb;
  v_key text; v_val jsonb; v_kiri text;
  v_scratch bigint;
  v_comp    int;
  v_ttl     text;
  v_report  jsonb;
BEGIN
  IF v_type IS NULL THEN
    -- 0.4.51 — the payload IS read as COALESCE(p_payload->'body', p_payload), so
    -- flat {type, …} and nested {body:{type, …}} both work and
    -- {type, body:{…}} is the ONE shape that cannot: the type sits outside the
    -- body this descends into. Saying "type_required" there names the single
    -- field the caller DID supply, and the caller re-sends it. Distinguish.
    IF p_payload ? '@type' OR p_payload ? 'type'
       OR (jsonb_typeof(p_payload->'body') = 'object' AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}}. NOT accepted: @type (never read), or {"type": …, "body": {…}} — that puts the type outside the body this verb descends into.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;

  -- P0-D mechanism 2 parity (pgCK#27): validate PREDICTS seal. seal refuses an
  -- undeclared type before the SHACL gate; validate must report the same, or
  -- validate <=> seal is a slogan. An undeclared type reports conforms=false
  -- with a violation naming it — never the vacuous conforms=true that let
  -- invented types look valid.
  v_comp := ckp._composed_shapes(v_proj);
  BEGIN
    IF NOT ckp._type_admitted(v_type, v_proj, v_comp) THEN
      RETURN jsonb_build_object('ok', true, 'type', v_type, 'conforms', false,
        'violations', jsonb_build_array(jsonb_build_object(
          'focusNode', v_type, 'resultMessage', 'type is not admitted — no shape targets it and it is declared by no class',
          'sourceConstraintComponent', 'ckp:AdmittedTypeConstraint')),
        'report', jsonb_build_object('conforms', false));
    END IF;
  END;

  -- Resolve the body's short keys to declared property IRIs (mirror ckp.create_typed) so validate
  -- accepts the same {type, …fields} shape as instance.create. Already-IRI keys pass through.
  v_ns := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;
  -- 0.4.51: the SAME map create_typed uses. This read composed while create read
  -- the kernel graph — validate ⟺ seal broken one layer below the gate.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_resolved := jsonb_build_object('type', v_type);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_body) LOOP
    CONTINUE WHEN v_key IN ('type', '@id', 'sub');
    IF position(':' in v_key) > 0 THEN v_kiri := v_key;
    ELSIF v_propmap ? v_key THEN v_kiri := v_propmap->>v_key;
    ELSE v_kiri := v_ns || v_key; END IF;
    v_resolved := v_resolved || jsonb_build_object(v_kiri, v_val);
  END LOOP;

  -- project the resolved candidate body to RDF in a scratch graph.
  -- 0.4.62 — THE DRY-RUN CANDIDATE IS THE SEAL'S CANDIDATE, all three parts.
  -- This serialized the body alone, so every requirement arriving by PARENT
  -- CLOSURE was invisible: wave:Pass receives EpochShape via wave:Pass ⊑
  -- ckp:Epoch, so epoch and surfaceDigest are demanded at seal — and this
  -- dry-run said conforms:true to a body missing both (ck-dev's escalation
  -- operation-1786642612862085000, reproduced here on 0.4.61 before fixing).
  -- Same root as the 0.4.60 propmap fix, one layer over: ancestors resolved in
  -- the property MAP but never STAMPED on the dry-run candidate. The derived
  -- stamps join too, exactly as seal composes them, so InstanceShape's
  -- requirements are previewed rather than falsely refused.
  v_ttl := ckp._body_to_ttl(v_resolved, v_subj, v_comp)
        || ckp._parent_closure_ttl(v_type, v_subj, v_comp)
        || ckp._stamps_to_ttl(v_subj, ckp._derived_stamps(v_subj, v_type, v_proj,
             NULLIF(trim(COALESCE(current_setting('ckp.requester', true), '')), ''), v_comp));
  v_scratch := pgrdf.add_graph('urn:ckp:validate:'||pg_backend_pid());
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    PERFORM pgrdf.parse_turtle(v_ttl, v_scratch, 'urn:ckp:validate#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'detail', SQLERRM);
  END;

  -- Full native W3C SHACL Core report against the COMPOSED SURFACE -- the graph
  -- ckp.seal actually gates on. This validated against <urn:ckp:%s/kernel/ck>,
  -- which holds a Kernel and three organs and NO shapes: measured on the bench,
  -- 30 triples and 0 sh:targetClass, versus a composed surface of 1258 triples
  -- and 27 targets. Nothing could ever be selected, and the only thing standing
  -- between that and a vacuous conforms:true is the no-target guard.
  -- "validate PREDICTS seal" (pgCK#27) was a slogan on all three axes -- shapes
  -- graph, property map, serializer overload. All three now match seal.
  v_report := pgrdf.validate(v_scratch, v_comp, 'native');
  PERFORM pgrdf.clear_graph(v_scratch);

  -- 0.4.72 — SEVERITY PARITY (validate ⟺ seal, fourth axis). The seal now
  -- refuses on Violations only and surfaces Warnings; a dry-run that reported
  -- conforms=false for a warnings-only body would predict a refusal the seal
  -- does not make — the exact split class this function exists to prevent.
  -- Partition identically: `conforms` reflects Violations; `warnings` carries
  -- the guidance band.
  DECLARE v_viol jsonb; v_warn jsonb;
  BEGIN
    SELECT COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IS DISTINCT FROM 'sh:Warning'
                                           AND r->>'resultSeverity' IS DISTINCT FROM 'sh:Info'), '[]'::jsonb),
           COALESCE(jsonb_agg(r) FILTER (WHERE r->>'resultSeverity' IN ('sh:Warning','sh:Info')), '[]'::jsonb)
      INTO v_viol, v_warn
      FROM jsonb_array_elements(COALESCE(v_report->'results', '[]'::jsonb)) r;
    RETURN jsonb_build_object('ok', true, 'type', v_type,
      'conforms',   (jsonb_array_length(v_viol) = 0),
      'violations', v_viol,
      'warnings',   v_warn,
      'report',     v_report);
  END;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  -- 0.4.51: read the SAME payload shapes ckp.validate_instance reads. It did
  -- COALESCE(p_payload->'body', p_payload) and this did not, so a nested
  -- {body:{type,…}} VALIDATED and then failed to CREATE — validate ⟺ seal
  -- broken at the envelope, one level above where it was broken at the
  -- property map. Both are closed in this version, in the same act, because
  -- fixing one and not the other just moves the disagreement.
  v_in      jsonb := CASE WHEN jsonb_typeof(p_payload->'body') = 'object'
                            AND ((p_payload->'body') ? 'type')
                          THEN p_payload->'body' ELSE p_payload END;
  v_type    text := v_in->>'type';
  v_proj    text := ckp._project();
  -- F-A / P0-C (pgCK#26): identity is SERVER-DERIVED from the verified
  -- connection (the ckp.requester GUC the trusted ingress sets from the
  -- NATS-verified bearer), NEVER the client payload. A payload {sub} is
  -- ignored — it cannot forge created_by or the participant claim. This is
  -- the same rule task.create and notify already carry; the generic path
  -- was the last reader of payload sub (measured: s58's instance.create
  -- case sealed participant:attacker before this fix).
  v_sub     text := current_setting('ckp.requester', true);
  N         text := 'urn:ckp:board/';       -- v3.7 core NS (gate + task.create)
  v_core    text[] := ARRAY['lifecycle_state'];                       -- recognized core keys → core NS
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    -- 0.4.51 — ABSENT is not the same as PRESENT-BUT-NOT-READABLE-HERE, and the
    -- old error said the first when the second was true. A caller following
    -- JSON-LD habit sends {"@type": …} and is told it gave no type; a caller
    -- nesting {"type": …, "body": {…}} is told the same. Both then re-send the
    -- one field they already sent. pgCK.MCP lost two calls to exactly this
    -- (F9) before reading the spec. Name the shape instead of the field.
    IF p_payload ? '@type' OR (jsonb_typeof(p_payload->'body') = 'object'
                               AND ((p_payload->'body') ? '@type')) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'type_not_readable_here',
        'hint', 'a type WAS supplied, in a position this verb does not read. Accepted: FLAT {"type": "<class IRI>", "<prop>": …}, or nested {"body": {"type": …, "<prop>": …}} — the same two shapes instance.validate reads. NOT accepted: @type, which is never read.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'the payload is flat: {"type": "<class IRI>", "<prop>": …}');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

  -- 0.4.51: the SAME map validate_instance uses. It read the kernel graph while
  -- validate read composed, so validate and create could resolve one JSON key to
  -- two different IRIs. See ckp._propmap.
  v_propmap := ckp._propmap(v_type, v_proj);

  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_in)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id', 'participant');     -- control keys, not data (sub/participant: identity is never payload)
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                             -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                                 -- declared localname -> its path IRI
    ELSIF v_key = ANY(v_core) THEN
      v_keyiri := N || v_key;                                        -- v3.7 core key -> core NS (gate + task.create)
    ELSE
      v_keyiri := v_ns || v_key;                                     -- other undeclared -> under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);         -- `->` value: preserves number/bool/object types
  END LOOP;

  v_body := v_body || jsonb_build_object(
    'urn:ckp:board/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    -- created_by from the VERIFIED requester (same shape as task.create), and
    -- the participant claim seal maps to core#participant — also verified.
    v_body := v_body || jsonb_build_object(
      N||'created_by', 'urn:ckp:participant:'||ckp._slug(v_sub),
      'participant', jsonb_build_object('sub', v_sub));
  END IF;

  PERFORM ckp.seal(v_iid, v_body);

  -- 0.4.72: the guidance band rides the reply. ckp.seal parked any
  -- Warning/Info-severity results in a txn-local GUC (cleared at each seal
  -- start); surfacing them here is what makes warning-shapes GUIDANCE instead
  -- of noise — sealed, and told why the fleet would prefer it shaped better.
  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1))
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;

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
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id); END IF;

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
      v_keyiri := v_key;                                    -- already a full IRI
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
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1))
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
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
  -- 0.4.72 adds the vision §2 trio: adopts-resolves (referential validity of
  -- Adoptions — the ontosys class), structural-pin (the graph being adopted is
  -- structurally the graph first pinned under that IRI), and no-warnings (the
  -- ratchet: guidance becomes law for kernels that adopt it, §2.0a).
  v_checks  text[] := ARRAY['digest-match','adopts-resolves','structural-pin','no-warnings'];
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

CREATE OR REPLACE FUNCTION ckp._oblig_adopts_resolves(p_instance_id text, p_body jsonb, p_project text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- 0.4.72 (vision §2.0b) — REFERENTIAL VALIDITY OF ADOPTIONS. Module-IRI-is-
-- graph-IRI: the adopts value IS the graph the composer copies, and a shape
-- cannot check that the referenced graph exists and is non-empty (body
-- locality) — so this is the obligations' half. Catches the ontosys class
-- (adopts naming a namespace with no graph behind it) and every judged,
-- load-bearing-for-nothing Adoption before it seals. Pure read, NULL = pass.
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_adopts text := p_body->>(C||'adopts');
BEGIN
  IF v_adopts IS NULL THEN RETURN NULL; END IF;  -- minCount is the gate's business
  IF NOT EXISTS (
    SELECT 1 FROM pgrdf._pgrdf_quads q
    JOIN pgrdf._pgrdf_graphs g ON g.graph_id = q.graph_id
    WHERE g.iri = v_adopts AND NOT q.is_inferred) THEN
    RETURN format('adopts-resolves: %s names no non-empty graph in this store — module-IRI-is-graph-IRI, and adopting a reference with nothing behind it seals a judged record that composes NOTHING (the load-bearing-for-nothing class, paid for five times). Load the module graph first, and check the spelling: the module GRAPH IRI, never the namespace', v_adopts);
  END IF;
  RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._oblig_structural_pin(p_instance_id text, p_body jsonb, p_project text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- 0.4.72 (vision §2.0b, the synapse-regrowth gate of the sporaxis design) —
-- the graph being adopted must be STRUCTURALLY the graph first pinned under
-- that IRI. First sight passes (nothing to compare, TOFU as declared); a
-- structural mismatch against an existing pin refuses: someone swapped the
-- module under a pinned name, and reload-relabelling is exactly what this
-- plane cannot be fooled by. DIFFERENT is conclusive (R-7). Pure read.
DECLARE
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_adopts text := p_body->>(C||'adopts');
  v_pin text; v_now text;
BEGIN
  IF v_adopts IS NULL THEN RETURN NULL; END IF;
  SELECT structural_digest INTO v_pin FROM ckp.adoption_pins WHERE graph_iri = v_adopts;
  IF v_pin IS NULL THEN RETURN NULL; END IF;   -- first sight, or pre-structural pin: nothing to hold against
  v_now := ckp._structural_digest(pgrdf.add_graph(v_adopts));
  IF v_now <> v_pin THEN
    RETURN format('structural-pin: the graph at %s is structurally %s… but was first pinned as %s… — unequal structural digests PROVE the graphs differ (this plane survives reload, so this is never a relabelling artifact). A legitimate update arrives as a NEW module IRI + Supersession, never a swap under a pinned name', v_adopts, left(v_now,12), left(v_pin,12));
  END IF;
  RETURN NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._oblig_no_warnings(p_instance_id text, p_body jsonb, p_project text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
-- 0.4.72 (vision §2.0a, the operator's ratchet) — "adopt the rule NO WARNINGS
-- ON SEAL: now they are law — comply, or others cannot rely on what you do."
-- The gate parked this seal's Warning/Info results in the txn-local GUC
-- moments ago; a kernel that adopted this obligation turns that guidance band
-- into refusals, and every conforming seal carries obligation:no-warnings as
-- a proof row — the warranty rides the fact, per-instance verifiable, so
-- reliance is a row rather than a reputation. Pure read of this txn's state.
DECLARE
  v_warn jsonb := NULLIF(current_setting('ckp.last_warnings', true), '')::jsonb;
BEGIN
  IF v_warn IS NULL OR jsonb_array_length(v_warn) = 0 THEN RETURN NULL; END IF;
  RETURN format('no-warnings: this kernel adopted the strict regime and the candidate carries %s warning(s) — first: %s on %s. Guidance is law here; shape the body until the warnings clear, or the fleet cannot rely on this kernel''s output at the grade it declared',
    jsonb_array_length(v_warn), v_warn->0->>'resultMessage', v_warn->0->>'resultPath');
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
      WHEN 'digest-match'    THEN v_fail := ckp._oblig_digest_match(p_instance_id, p_body, p_project);
      WHEN 'adopts-resolves' THEN v_fail := ckp._oblig_adopts_resolves(p_instance_id, p_body, p_project);
      WHEN 'structural-pin'  THEN v_fail := ckp._oblig_structural_pin(p_instance_id, p_body, p_project);
      WHEN 'no-warnings'     THEN v_fail := ckp._oblig_no_warnings(p_instance_id, p_body, p_project);
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
  -- 0.4.71 — pgRDF#118 CONSUMED: since engine 0.6.31 the loader records the
  -- exact input bytes' sha256 on _pgrdf_graphs (turtle funnel; staged/bulk/
  -- nquads do not yet — the boundary their PR states). When the column exists,
  -- the sealed Adoption's file-byte sourceDigest stops being decorative: it is
  -- COMPARED against what the loader measured. Guarded: on an older engine
  -- the fields read null and verifiable stays false with the old reason.
  v_has_src boolean := EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='pgrdf' AND table_name='_pgrdf_graphs' AND column_name='source_sha256');
  v_src text; v_loads int; v_sealed_src text;
BEGIN
  FOREACH v_iri IN ARRAY ckp._adopted_graphs(v_proj) LOOP
    SELECT graph_digest INTO v_pin FROM ckp.adoption_pins WHERE graph_iri = v_iri;
    v_now := ckp._surface_digest(pgrdf.add_graph(v_iri));
    IF v_pin IS NOT NULL AND v_pin <> v_now THEN v_drift := true; END IF;
    v_src := NULL; v_loads := NULL;
    IF v_has_src THEN
      SELECT g.source_sha256, g.source_loads INTO v_src, v_loads
        FROM pgrdf._pgrdf_graphs g WHERE g.iri = v_iri;
    END IF;
    SELECT a.body->>(N||'sourceDigest') INTO v_sealed_src FROM ckp.instances a
      WHERE a.body->>'type' = N||'Adoption' AND a.body->>(N||'adopts') = v_iri
      ORDER BY a.ts_created DESC LIMIT 1;
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
      'sourceRecorded',  v_src,
      'sourceLoads',     v_loads,
      'sourceDigestVerifiable', (v_src IS NOT NULL),
      'sourceDigestMatch', CASE WHEN v_src IS NULL OR v_sealed_src IS NULL THEN NULL
                                ELSE (v_src = v_sealed_src) END,
      -- 0.4.72: the why names ROW-state separately from ENGINE-capability —
      -- 0.4.71's two-branch text blamed the engine for a null that only meant
      -- "this graph predates recording or took an unrecorded path" (measured
      -- live: verdict said recording exists while row-why said it did not).
      'why', CASE WHEN v_src IS NOT NULL
        THEN 'the LOADER measured these bytes (pgRDF#118, engine >= 0.6.31): sourceRecorded is the sha256 of the exact input the parser consumed, sourceLoads > 1 self-reports that whole-graph byte identity no longer holds. sourceDigestMatch compares the sealed Adoption claim against the loader record — false is a finding, null means one side is absent.'
        WHEN v_has_src
        THEN 'this ENGINE records loader-side digests (pgRDF#118), but THIS graph has no record — loaded before recording existed, or via an unrecorded path (staged/bulk/nquads, the pgRDF#120 coverage boundary). A re-load through the turtle funnel would record. The null is the row''s history, not the engine''s capability.'
        ELSE 'sourceDigest is a FILE-BYTE sha256; a graph cannot recompute file bytes, and this engine does not record loader-side digests (pgRDF#118 lands at 0.6.31). The substrate''s halves: the COPY pin detects in-store drift; the STRUCTURAL pin survives reload. Equal structural digests are evidence, not proof; unequal ARE proof of difference.' END);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj,
    'modules', v_rows, 'drifted', v_drift,
    'completeness', jsonb_build_object(
      'verdict', CASE WHEN v_has_src THEN 'complete for recorded loads'
                      ELSE 'UNKNOWN — engine predates loader-side recording' END,
      'counters', ckp._engine_counters()),
    'note', 'drifted:true means an adopted module''s graph no longer matches its first-composition pin — the module was swapped or edited under an unsuperseded Adoption. A legitimate update arrives as a NEW Adoption + Supersession, which re-pins.');
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.fleet_adoptions(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_rows jsonb;
  v_bad  int;
BEGIN
  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'intoProject', row->>'adopts'), '[]'::jsonb),
         COALESCE(sum(CASE WHEN (row->>'malformed')::boolean THEN 1 ELSE 0 END), 0)
    INTO v_rows, v_bad
  FROM (
    SELECT jsonb_build_object(
      'adoption',   a.id,
      'intoProject', a.body->>(N||'intoProject'),
      'adopts',      a.body->>(N||'adopts'),
      'sealedBy',    a.body->>(N||'createdBy'),
      'graphQuads',  (SELECT count(*) FROM pgrdf._pgrdf_quads q
                        JOIN pgrdf._pgrdf_graphs g ON g.graph_id = q.graph_id
                       WHERE g.iri = a.body->>(N||'adopts') AND NOT q.is_inferred),
      'malformed',   NOT EXISTS (SELECT 1 FROM pgrdf._pgrdf_quads q2
                        JOIN pgrdf._pgrdf_graphs g2 ON g2.graph_id = q2.graph_id
                       WHERE g2.iri = a.body->>(N||'adopts') AND NOT q2.is_inferred),
      'structuralPin', (SELECT p.structural_digest FROM ckp.adoption_pins p
                         WHERE p.graph_iri = a.body->>(N||'adopts'))) AS row
    FROM ckp.instances a
    WHERE a.body->>'type' = N||'Adoption'
      AND NOT EXISTS (SELECT 1 FROM ckp.instances s
                       WHERE s.body->>'type' = N||'Supersession'
                         AND s.body->>(N||'supersedes') = a.body->>'@id')
  ) sub;
  RETURN jsonb_build_object('ok', true,
    'adoptions', v_rows,
    'malformedCount', v_bad,
    'note', 'malformed:true = the adopts IRI names NO non-empty graph in this store — a judged Adoption composing NOTHING (module-IRI-is-graph-IRI; the namespace-instead-of-graph and blank-adopts classes). The cure is Supersession + a fresh Adoption naming the module GRAPH IRI. Per-kernel enforcement of this exists as the adopts-resolves obligation, adopted by agreement.',
    'completeness', jsonb_build_object(
      'verdict', 'complete for sealed, unsuperseded Adoptions in this store',
      'counters', ckp._engine_counters()));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.surface_explain(p_payload jsonb, p_project text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := COALESCE(p_project, ckp._project());
  v_type text := COALESCE(p_payload->>'type', p_payload->>'@type');
  v_comp bigint;
  v_map  jsonb;
  v_props jsonb;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required',
      'hint', 'surface.explain {"type": "<class IRI>"} — the declared contract WITH its teaching prose');
  END IF;
  v_comp := ckp._composed_shapes(v_proj);
  v_map  := ckp._propmap(v_type, v_proj);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'name', k, 'path', v_map->>k,
           'comment', (SELECT o.lexical_value FROM pgrdf._pgrdf_quads q
                         JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
                         JOIN pgrdf._pgrdf_dictionary p ON p.id = q.predicate_id
                         JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
                        WHERE q.graph_id = v_comp AND NOT q.is_inferred
                          AND s.lexical_value = v_map->>k
                          AND p.lexical_value = 'http://www.w3.org/2000/01/rdf-schema#comment'
                        LIMIT 1)) ORDER BY k), '[]'::jsonb)
    INTO v_props
  FROM jsonb_object_keys(v_map) k;
  RETURN jsonb_build_object('ok', true, 'type', v_type, 'kernel', v_proj,
    'comment', (SELECT o.lexical_value FROM pgrdf._pgrdf_quads q
                  JOIN pgrdf._pgrdf_dictionary s ON s.id = q.subject_id
                  JOIN pgrdf._pgrdf_dictionary p ON p.id = q.predicate_id
                  JOIN pgrdf._pgrdf_dictionary o ON o.id = q.object_id
                 WHERE q.graph_id = v_comp AND NOT q.is_inferred
                   AND s.lexical_value = v_type
                   AND p.lexical_value = 'http://www.w3.org/2000/01/rdf-schema#comment'
                 LIMIT 1),
    'properties', v_props,
    'note', 'comments are read from the COMPOSED surface, asserted-only — what the gate judges is what this prose explains. A property with a null comment is declared but untaught; that gap is the module author''s, and now it is visible.');
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

  WHEN 'surface.explain' THEN
    res := ckp.surface_explain(p_payload, v_proj);

  WHEN 'fleet.adoptions' THEN
    res := ckp.fleet_adoptions(p_payload);

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

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgck','surface.explain','input.kernel.pgck.action.surface.explain','instance'),
  ('pgck','fleet.adoptions','input.kernel.pgck.action.fleet.adoptions','instance')
ON CONFLICT (kernel, verb) DO NOTHING;
-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
