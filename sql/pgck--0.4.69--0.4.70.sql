-- pgck 0.4.69 → 0.4.70 — IDENTITY EVIDENCE: verified-at-time becomes sealable
--
-- The fleet identity contract on the wire (pgRDF operation-1786906298085342000
-- ⇄ pgck operation-1786897156122855000): two GUCs, relay-set on the channel
-- clients cannot write, land as proof rows on the plural-proofs joint (0.4.65)
-- so the evidence rides the ledger into every future epoch:
--
--   ckp.token_residue  → proof row method='token-residue', digest = the claims
--                        fingerprint itself (iss/kid/sub/exp sha256, 64-hex).
--                        NEVER the token, structurally: a JWT-shaped value
--                        REFUSES the seal — bearer tokens replay, and a raw
--                        credential in the evidence plane is permanent.
--   ckp.grant_ref      → proof row method='grant-ref:<urn>', digest = the body
--                        sha (evidence about THIS seal). The acting voted
--                        Grant's URN is readable for resolve-never-believe
--                        custody (pgRDF#122).
--
-- Absent GUCs leave no rows — the absence IS the honest record (raw plane,
-- tests). The attach list is CLOSED at these two; anything more is argued for
-- on the wire, never slipped in. Golden s66: three proofs with declared
-- semantics · the never-the-token refusal · absence stays absent · plural
-- readers hold.
--
-- Changed: seal.
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

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
