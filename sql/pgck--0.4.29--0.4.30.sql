-- pgck 0.4.29 -> 0.4.30 — P0-D mechanism 2: fail closed on the UNDECLARED TYPE (pgCK#27).
--
-- SHACL is target-driven: an invented type URN is targeted by no shape, so
-- validation never runs and the body seals verified:true — the live defect.
-- Adds ckp._type_admitted (a substrate LOOKUP over the loaded core+ck+board
-- surface, not a shape — the SS4.4 generated-shape form is blocked on
-- pgRDF#102 sh:in-over-IRIs), wires it into ckp.seal BEFORE the measured gate,
-- and into ckp.validate_instance so validate PREDICTS seal (validate<=>seal).
-- A transitional allowance passes legacy v3.7-namespaced board types (pgCK#46).
-- All three bodies are byte-identical to sql/pgck-baseline.sql (fresh==upgraded).

CREATE OR REPLACE FUNCTION ckp._type_admitted(p_type text, p_project text, p_comp integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_comp_iri text; v_board_iri text; v_ask text;
BEGIN
  IF p_type IS NULL OR position(':' in p_type) = 0 THEN
    RETURN false;   -- no resolvable type is not an admitted type
  END IF;
  -- TRANSITIONAL ALLOWANCE (pgCK#46): the legacy board path (task.create,
  -- notify) still EMITS v3.7-namespaced instance types (Task, Goal, Message)
  -- while their shapes are v3.11 — so those types are targeted by no shape and
  -- would refuse here. That is the #46 residue, not an invented URN; tolerate
  -- it until #46 re-points the body construction, at which point the board
  -- path becomes non-vacuously validated and this allowance is deleted.
  IF p_type LIKE 'https://conceptkernel.org/ontology/v3.7/%' THEN
    RETURN true;
  END IF;
  -- Admitted = the type is DECLARED (a shape targets it, or it is a declared
  -- class) anywhere the kernel loaded: the composed core+ck surface OR the
  -- project board. Reads the same surfaces the gate/self-test consult — never
  -- a second authority. An invented URN in none of them is refused.
  v_comp_iri  := pgrdf.graph_iri(p_comp);
  v_board_iri := format('urn:ckp:%s/kernel/board', p_project);
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask
  FROM pgrdf.sparql(format($q$
    PREFIX sh:   <http://www.w3.org/ns/shacl#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX owl:  <http://www.w3.org/2002/07/owl#>
    ASK WHERE { GRAPH ?g {
      { ?s sh:targetClass <%s> } UNION { <%s> a rdfs:Class } UNION { <%s> a owl:Class }
    } FILTER(?g IN (<%s>, <%s>)) }
  $q$, p_type, p_type, p_type, v_comp_iri, v_board_iri)) j
  LIMIT 1;
  RETURN COALESCE(v_ask, 'false') = 'true';
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
    v_cand := ckp._body_to_ttl(p_body, p_instance_id, v_comp)
              || ckp._parent_closure_ttl(v_type, p_instance_id, v_comp)
              || ckp._derived_stamp_ttl(p_instance_id, v_type, v_project, v_participant, v_comp);
    v_report := ckp.validate_report(v_cand, v_comp);
    IF (v_report->>'conforms') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'ckp.seal: payload fails the composed shape gate: %',
        COALESCE(ckp._report_summary(v_report), v_report::text);
    END IF;
  END;

  -- 2. MATERIALIZE durable instance.
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
CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);
  v_type    text := v_body->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_subj    text := 'urn:ckp:validate:'||pg_backend_pid();
  v_ns      text;
  v_propmap jsonb;
  v_resolved jsonb;
  v_key text; v_val jsonb; v_kiri text;
  v_scratch bigint;
  v_kernel  bigint;
  v_ttl     text;
  v_report  jsonb;
BEGIN
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;

  -- P0-D mechanism 2 parity (pgCK#27): validate PREDICTS seal. seal refuses an
  -- undeclared type before the SHACL gate; validate must report the same, or
  -- validate <=> seal is a slogan. An undeclared type reports conforms=false
  -- with a violation naming it — never the vacuous conforms=true that let
  -- invented types look valid.
  DECLARE v_comp0 int := ckp._composed_shapes(v_proj);
  BEGIN
    IF NOT ckp._type_admitted(v_type, v_proj, v_comp0) THEN
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
  SELECT COALESCE(jsonb_object_agg(regexp_replace(path, '^.*[/#]', ''), path), '{}'::jsonb)
    INTO v_propmap
  FROM (
    SELECT DISTINCT j->>'path' AS path
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?path WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
        ?s sh:targetClass <%s> ; sh:property ?p . ?p sh:path ?path } }
    $q$, v_proj, v_type)) AS j WHERE j->>'path' IS NOT NULL
  ) p;
  v_resolved := jsonb_build_object('type', v_type);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_body) LOOP
    CONTINUE WHEN v_key IN ('type', '@id', 'sub');
    IF position(':' in v_key) > 0 THEN v_kiri := v_key;
    ELSIF v_propmap ? v_key THEN v_kiri := v_propmap->>v_key;
    ELSE v_kiri := v_ns || v_key; END IF;
    v_resolved := v_resolved || jsonb_build_object(v_kiri, v_val);
  END LOOP;

  -- project the resolved candidate body to RDF in a scratch graph.
  v_ttl := ckp._body_to_ttl(v_resolved, v_subj);
  v_scratch := pgrdf.add_graph('urn:ckp:validate:'||pg_backend_pid());
  PERFORM pgrdf.clear_graph(v_scratch);
  BEGIN
    PERFORM pgrdf.parse_turtle(v_ttl, v_scratch, 'urn:ckp:validate#');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pgrdf.clear_graph(v_scratch);
    RETURN jsonb_build_object('ok', false, 'error', 'project_error', 'detail', SQLERRM);
  END;

  -- full native W3C SHACL Core report against the kernel shapes.
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', v_proj));
  v_report := pgrdf.validate(v_scratch, v_kernel, 'native');
  PERFORM pgrdf.clear_graph(v_scratch);

  RETURN jsonb_build_object('ok', true, 'type', v_type,
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb),
    'report',     v_report);
END;
$function$
;

-- Ring-1: replacements + the new helper must land the same ring as installs.
DO $floor_0430$
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
$floor_0430$;

REVOKE ALL ON FUNCTION ckp._type_admitted(text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ckp._type_admitted(text,text,integer) FROM ck_participant;
GRANT EXECUTE ON FUNCTION ckp._type_admitted(text,text,integer) TO ck_substrate;

CALL ckp._enforce_internal_floor();
