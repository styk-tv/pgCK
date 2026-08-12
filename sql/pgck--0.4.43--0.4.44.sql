-- pgck 0.4.44 — identity has ONE source: the verified connection
--
-- MEASURED DEFECT (pgCK.MCP, over a callout-verified connection — the only
-- setting in which this is evidence at all). A single seal carried two
-- identities:
--   ckp:ownedBy    urn:ckp:participant:f767f1b7-…      (verified connection)
--   ckp:createdBy  urn:ckp:participant:anon:0e93c962-…  (payload absent ⇒ anon)
-- One transaction, one connection, two answers — "owned by someone, created by
-- nobody".
--
-- CAUSE. ckp.seal resolved the participant from p_body->'participant'->>'sub'
-- — the payload — while germination stamped ownedBy from `ckp.requester`, the
-- transaction-local GUC the relay sets from the callout-verified connection
-- (src/inbound_dispatch.rs). Two sources for one fact.
--
-- CONSEQUENCE BEYOND THE MISMATCH. createdBy was client-assertable: whatever
-- sub the payload carried became the sealed author. That is precisely what the
-- four InstanceShape stamps exist to prevent, and it is the forgeable
-- created_by ceiling — closable here, because the verified sub is already in
-- the GUC.
--
-- WHAT IS AND IS NOT ESTABLISHED. Established: ckp.seal ignores ckp.requester
-- and resolves the participant from the payload. NOT established: what an
-- id-scoped subject would produce — a client whose library also puts
-- participant claims in the BODY may well see createdBy resolve. That would
-- not make it correct: it would be a client asserting its own authorship,
-- which is the defect, not the fix. Hence the rule below rather than a
-- client-side workaround.
--
-- (A direct-SQL reproduction proves nothing here: ckp.requester is hand-set on
-- such a connection, so both fields are caller-asserted. Only the door path
-- carries a derived identity.)
--
-- RULE. The verified connection wins. A conflicting payload sub is ignored,
-- never merged. The payload arm survives only where there is no verified
-- connection (direct SQL, tests), and anon only where there is neither.
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
  v_req    TEXT;
  v_display TEXT;
  v_email  TEXT;
  v_participant TEXT;
  N        TEXT := 'https://conceptkernel.org/ontology/v3.11/core#';
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
-- EMPTY AFFORDANCES MUST MEAN NONE.
--
-- `affordances` reports the SEALED ckp:Affordance set for the calling kernel,
-- filtered on the unforgeable producedBy stamp -- correctly returning [] for a
-- kernel with nothing declared. Dispatch, however, authorized from a different
-- set (ckp.affordance_registry), so an empty affordance list did not mean an
-- empty surface. Two views of one fact, resolving toward the permissive side.
--
-- Measured: pgck-mcp 0.2.32 slugged its kernel segment pgCK -> pgck. All 26
-- registry rows name pgCK, so affordances went 3 -> EMPTY while dispatch
-- carried on. Reported as d-28-sah-1.
--
-- Fail-closed now, with one bootstrap exception (kernel.germinate) because a
-- kernel that does not exist yet cannot own a registry row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp.registry_lookup(p_kernel text, p_verb text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
  -- EMPTY MEANS NONE. A kernel is authorized for the verbs its OWN registry
  -- rows name. It is never authorized for another kernel's, and never for
  -- EVERYTHING on the grounds that it has none -- degrading an empty surface
  -- to the full surface is fail-open authorization (d-28-sah-1). All 26 seeded
  -- rows name kernel pgCK, so every other workspace resolves to zero rows,
  -- which is a true answer meaning none.
  --
  -- ONE bootstrap exception, the narrowest that still permits creation: a
  -- kernel that does not exist yet cannot own a registry row, so without this
  -- no kernel could ever be created through the door. kernel.germinate is the
  -- only verb reachable with no surface -- it refuses anonymous callers and
  -- stamps ownedBy from the verified connection, so reaching it proves an
  -- identity rather than bypassing one.
  SELECT to_jsonb(r) FROM ckp.affordance_registry r
  WHERE r.verb = p_verb
    AND (r.kernel = p_kernel OR p_verb = 'kernel.germinate')
  ORDER BY (r.kernel = p_kernel) DESC
  LIMIT 1;
$function$
;

-- ---------------------------------------------------------------------------
-- ROUTE PARITY: ckp.affordances_of and ckp._affordance_schema existed ONLY in
-- the 0.4.35--0.4.36 migration, never in the baseline, while ckp.dispatch has
-- called affordances_of since 0.4.36. A FRESH install therefore had a verb
-- that raises "function does not exist" -- invisible because the smoke suite
-- reaches `affordances` only on an upgraded substrate. Added to the baseline;
-- repeated here so both routes carry identical text.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ckp._affordance_schema(p_shape_iri text, p_comp integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_giri text;
  v_props jsonb;
BEGIN
  IF p_shape_iri IS NULL OR p_comp IS NULL THEN RETURN NULL; END IF;
  SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_comp;
  IF v_giri IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'path',     j->>'path',
           'name',     regexp_replace(j->>'path', '^.*[#/]', ''),
           'datatype', j->>'dt',
           'required', CASE WHEN COALESCE((j->>'mn')::int, 0) >= 1 THEN true ELSE NULL END,
           'maxCount', (j->>'mx')::int,
           'nodeKind', regexp_replace(COALESCE(j->>'nk',''), '^.*[#/]', ''),
           'pattern',  j->>'pat'
         )) ORDER BY j->>'path')
    INTO v_props
  FROM pgrdf.sparql(format($q$
    PREFIX sh: <http://www.w3.org/ns/shacl#>
    SELECT ?path ?dt ?mn ?mx ?nk ?pat WHERE { GRAPH <%s> {
      <%s> sh:property ?p . ?p sh:path ?path .
      OPTIONAL { ?p sh:datatype ?dt } OPTIONAL { ?p sh:minCount ?mn }
      OPTIONAL { ?p sh:maxCount ?mx } OPTIONAL { ?p sh:nodeKind ?nk }
      OPTIONAL { ?p sh:pattern ?pat } } }$q$, v_giri, p_shape_iri)) j;

  -- Unresolvable => NULL, never an empty contract. A shape that resolves to
  -- nothing and a shape that is not there must not read the same.
  IF v_props IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('shape', p_shape_iri, 'properties', v_props);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.affordances_of(p_project text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N       text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_kern  text := 'urn:ckp:'||p_project||'/kernel/ck';
  v_epoch int  := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = p_project), 0);
  v_comp  int;
  v_list  jsonb;
  v_unsealed jsonb;
BEGIN
  v_comp := ckp._composed_shapes(p_project);

  SELECT jsonb_agg(a ORDER BY a->>'name') INTO v_list FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'name',    regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', ''),
      'iri',     i.body->>'@id',
      'in',      i.body->>(N||'inTopic'),
      'out',     i.body->>(N||'outTopic'),
      'plane',   i.body->>(N||'plane'),
      'delegate', (i.body->>(N||'delegate'))::boolean,
      'inShape', i.body->>(N||'inShape'),
      -- inShape resolved into a real input contract, or null + a marker. §4.5:
      -- report what was found; never invent a contract for a dangling IRI.
      'schema',  ckp._affordance_schema(i.body->>(N||'inShape'), v_comp),
      'schema_resolved',
                 CASE WHEN i.body ? (N||'inShape')
                      THEN ckp._affordance_schema(i.body->>(N||'inShape'), v_comp) IS NOT NULL
                      ELSE NULL END,
      -- provenance for the affordance ITSELF (root: derivedBy minCount 1)
      'derivedBy', i.body->>(N||'derivedBy'),
      'sealedAtEpoch', (i.body->>(N||'sealedAtEpoch'))::int
    )) AS a
    FROM ckp.instances i
    WHERE i.body->>'type' = N||'Affordance'
      -- kernel filter: producedBy is the substrate-stamped kernel, unforgeable
      AND i.body->>(N||'producedBy') = v_kern
      -- retirement honoured: retired AT or BEFORE the current epoch is gone
      AND (NOT (i.body ? (N||'retiredAtEpoch'))
           OR (i.body->>(N||'retiredAtEpoch'))::int > v_epoch)
  ) s;

  -- The #56 split, made VISIBLE: verbs dispatch resolves that no sealed
  -- Affordance declares. Reported, never merged — a union would hide exactly
  -- the hand-registered action the root says cannot hide.
  SELECT jsonb_agg(r.verb ORDER BY r.verb) INTO v_unsealed
  FROM ckp.affordance_registry r
  WHERE r.kernel = p_project
    AND NOT EXISTS (
      SELECT 1 FROM ckp.instances i
      WHERE i.body->>'type' = N||'Affordance'
        AND i.body->>(N||'producedBy') = v_kern
        AND regexp_replace(i.body->>(N||'inTopic'), '^input\.kernel\.[^.]+\.action\.', '') = r.verb);

  RETURN jsonb_build_object(
    'ok', true,
    'kernel', p_project,
    'epoch', v_epoch,
    'affordances', COALESCE(v_list, '[]'::jsonb),
    'unsealed', COALESCE(v_unsealed, '[]'::jsonb));
END;
$function$
;
