-- pgck 0.4.24 -> 0.4.25
-- P0-A0 (pgCK#23): ckp.boot() could never run — the core ontology was never loaded.
--
-- Two paths bound RDF graphs: one by explicit id read from ckp.config, one by
-- IRI with an auto-assigned id. Whichever ran first won the id, which left
-- core_graph_id pointing at the kernel graph. ckp.boot() then raised
--   add_graph: graph_id 1 is bound to a different IRI (urn:ckp:<project>/kernel/ck)
-- on every invocation, so urn:ckp:core held 0 triples while ontology/core.ttl
-- declared 8 sh:NodeShape.
--
-- Consequence: ckp.seal guards its own ledger and proof with
-- ckp.validate(ttl, core_graph_id) and raises 'fails ckp:LedgerEntryShape
-- (core governance)'. Against an empty shapes graph that exception is
-- UNREACHABLE. Measured before this change:
--   ckp.validate('<x> a ckp:LedgerEntry ; ckp:bodySha "NOT-A-SHA" ; ckp:sig "" .', core)
--     -> conforms = true
-- After: conforms = false, and a well-formed entry still conforms = true.
--
-- Fix: resolve the core graph BY IRI and record the id it was given. Never
-- assume an id. Then fail loudly rather than run with an unenforced core.

CREATE OR REPLACE PROCEDURE ckp.boot(p_core_ttl_path TEXT DEFAULT '/ontology/core.ttl')
LANGUAGE plpgsql AS $$
DECLARE v_core INT; v_ttl TEXT; v_shapes INT;
BEGIN
  PERFORM pgrdf.shmem_reset();
  -- P0-A0 (pgCK#23): resolve the core graph BY IRI and record the id it got.
  -- Never assume an id from config. Two paths bound graphs — one by explicit
  -- id from ckp.config, one by IRI with an auto-assigned id — and whichever ran
  -- first won the id. That left core_graph_id pointing at the kernel graph and
  -- boot raising 'graph_id 1 is bound to a different IRI' on every run, so the
  -- core ontology was never loaded and every ckp.validate(_, core) conformed
  -- trivially against an empty shapes graph.
  v_core := pgrdf.add_graph('urn:ckp:core');
  INSERT INTO ckp.config(k,v) VALUES ('core_graph_id', v_core::text)
    ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
  -- Fail loudly. An empty core graph is not a runnable state: it makes the
  -- seal's own ledger/proof gate unreachable and every core constraint inert.
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF v_shapes = 0 THEN
    RAISE EXCEPTION 'ckp.boot: core ontology at % loaded 0 sh:NodeShape — refusing to run with an unenforced core', p_core_ttl_path;
  END IF;
  RAISE NOTICE 'ckp.boot: core graph % loaded from %, % NodeShapes', v_core, p_core_ttl_path, v_shapes;
END;
$$;

ALTER PROCEDURE ckp.boot(text) OWNER TO ck_substrate;

-- ─────────────────────────────────────────────────────────────────────
-- P0-A (pgCK#24): composed shapes graph + parent-closure stamp.
--
-- 1. COMPOSITION. The instance gate queried only urn:ckp:<project>/kernel/ck,
--    which holds the kernel's own shapes and no core shapes. Pointing a real
--    validator at that graph reports success and enforces nothing. Measured
--    on the bench, same malformed ledger entry, two shapes graphs:
--      vs kernel graph   -> conforms = true    (bodySha "NOT-A-SHA", sig "")
--      vs composed graph -> conforms = false
--    core 297 + kernel 55 = composed 348 triples; 2 NodeShapes -> 10.
--
-- 2. PARENT-CLOSURE STAMP (RULE-6). pgrdf.validate does NOT entail, and
--    entailment is per-graph. Either gap silently disables the provability
--    spine while returning conforms=true. So the ancestors of the declared
--    type are stamped explicitly at projection time — no closure pass on the
--    write path, no dependence on a materialize that may not have run.
--    Measured, instance of a kernel-declared subclass of ckp:Task:
--      without stamp -> conforms = true    (targeted by nothing)
--      with stamp    -> conforms = false   (TaskShape targets it)
--
-- Namespace-agnostic: both operate on whatever root is loaded.

CREATE OR REPLACE FUNCTION ckp._composed_shapes(p_project text DEFAULT 'demo'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_core int; v_kernel int; v_comp int;
BEGIN
  v_core   := pgrdf.add_graph('urn:ckp:core');
  v_kernel := pgrdf.add_graph(format('urn:ckp:%s/kernel/ck', p_project));
  v_comp   := pgrdf.add_graph(format('urn:ckp:%s/shapes/composed', p_project));
  PERFORM pgrdf.clear_graph(v_comp);
  PERFORM pgrdf.copy_graph(v_core,   v_comp);
  PERFORM pgrdf.copy_graph(v_kernel, v_comp);
  -- Entailment is per-graph and pgrdf.validate does not entail, so the closure
  -- is computed HERE, once, rather than depended on at validate time.
  PERFORM pgrdf.materialize(v_comp);
  RETURN v_comp;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._parent_closure_ttl(p_type text, p_subj text, p_graph integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_ttl text := ''; j jsonb;
BEGIN
  IF p_type IS NULL OR p_graph IS NULL THEN RETURN ''; END IF;
  FOR j IN SELECT * FROM pgrdf.sparql(format($q$
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      SELECT DISTINCT ?parent WHERE {
        GRAPH <%s> { <%s> rdfs:subClassOf+ ?parent }
        FILTER(isIRI(?parent)) }
    $q$, (SELECT iri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_graph), p_type))
  LOOP
    v_ttl := v_ttl || '<'||p_subj||'> a <'||(j->>'parent')||'> .'||chr(10);
  END LOOP;
  RETURN v_ttl;
END;
$function$
;

ALTER FUNCTION ckp._composed_shapes(text)                OWNER TO ck_substrate;
ALTER FUNCTION ckp._parent_closure_ttl(text, text, int)  OWNER TO ck_substrate;

-- ─────────────────────────────────────────────────────────────────────
-- P0-B (pgCK#25): the seal validates against the COMPOSED graph.
--
-- Replaces the hand-rolled sh:minCount SPARQL scan that ran against the
-- KERNEL graph only. That gate saw no core shape and read past every other
-- SHACL component the engine enforces. Measured at the SEAL, all required
-- props present so the OLD gate would have accepted every one:
--   bodySha "NOT-A-SHA"  -> REFUSED (PatternConstraintComponent)
--   sig "short"          -> REFUSED (MinLengthConstraintComponent)
--   fully valid body     -> ACCEPTED   (control)
--
-- Wiring it exposed a second defect, fixed here: the JSON->RDF projection
-- was LOSSY on datatypes. Every JSON string became a plain xsd:string
-- literal, so the 5 property shapes declaring xsd:dateTime / xsd:integer /
-- xsd:boolean refused CORRECT data. The projection now asks the same graph
-- the gate validates against what datatype each predicate is declared with.
-- Without this the gate is inoperable: it refuses every typed literal.
--
-- Also lands the RULE-11 obligation: pgrdf.validate returns JSONB, so
-- ckp:ValidationReport had NO PRODUCER. ckp.validation_report_ttl() is it.

CREATE OR REPLACE FUNCTION ckp._report_summary(p_report jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT string_agg(
           regexp_replace(v->>'sourceConstraintComponent','.*shacl#','')
           || CASE WHEN v->>'resultPath' IS NOT NULL
                   THEN ' on '||regexp_replace(v->>'resultPath','.*[#/]','') ELSE '' END
           || COALESCE(' ('||(v->>'resultMessage')||')',''), '; ')
  FROM jsonb_array_elements(COALESCE(p_report->'results','[]'::jsonb)) v;
$function$
;

CREATE OR REPLACE FUNCTION ckp.validation_report_ttl(p_report jsonb, p_subj text DEFAULT 'urn:ckp:report:1'::text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE v_ttl text; v jsonb; i int := 0; r text;
BEGIN
  v_ttl := '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)
        || '@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .'||chr(10)
        || '<'||p_subj||'> a sh:ValidationReport ; sh:conforms '
        || CASE WHEN (p_report->>'conforms')='true' THEN '"true"' ELSE '"false"' END
        || '^^xsd:boolean .'||chr(10);
  FOR v IN SELECT * FROM jsonb_array_elements(COALESCE(p_report->'results','[]'::jsonb))
  LOOP
    i := i + 1;
    r := p_subj||':r'||i;
    v_ttl := v_ttl
      || '<'||p_subj||'> sh:result <'||r||'> .'||chr(10)
      || '<'||r||'> a sh:ValidationResult ;'||chr(10)
      || '  sh:resultSeverity sh:Violation ;'||chr(10)
      || '  sh:sourceConstraintComponent <'||(v->>'sourceConstraintComponent')||'> '
      || CASE WHEN v->>'focusNode' IS NOT NULL
              THEN ';'||chr(10)||'  sh:focusNode <'||(v->>'focusNode')||'> ' ELSE '' END
      || CASE WHEN v->>'resultPath' IS NOT NULL
              THEN ';'||chr(10)||'  sh:resultPath <'||(v->>'resultPath')||'> ' ELSE '' END
      || CASE WHEN v->>'resultMessage' IS NOT NULL
              THEN ';'||chr(10)||'  sh:resultMessage "'
                   ||replace(replace(v->>'resultMessage','\','\\'),'"','\"')||'" ' ELSE '' END
      || '.'||chr(10);
  END LOOP;
  RETURN v_ttl;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._body_to_ttl(p_body jsonb, p_subj text, p_shapes_graph integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type text := p_body->>'type';
  v_ttl text; v_key text; v_val jsonb; v_obj text; s text;
  v_dt jsonb := '{}'::jsonb; j jsonb; v_giri text; v_d text;
BEGIN
  IF p_shapes_graph IS NOT NULL THEN
    SELECT iri INTO v_giri FROM pgrdf._pgrdf_graphs WHERE graph_id = p_shapes_graph;
    FOR j IN SELECT * FROM pgrdf.sparql(format($q$
        PREFIX sh: <http://www.w3.org/ns/shacl#>
        SELECT ?path ?dt WHERE { GRAPH <%s> { ?s sh:property ?p . ?p sh:path ?path ; sh:datatype ?dt } }
      $q$, v_giri))
    LOOP
      v_dt := v_dt || jsonb_build_object(j->>'path', j->>'dt');
    END LOOP;
  END IF;

  v_ttl := '<'||p_subj||'> a <'||COALESCE(v_type,'urn:ckp:Unknown')||'> .'||chr(10);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_body)
  LOOP
    CONTINUE WHEN v_key IN ('type','@id','participant','participant_display_name','participant_email');
    CONTINUE WHEN position(':' in v_key) = 0;
    v_d := v_dt->>v_key;
    IF    jsonb_typeof(v_val) = 'number'  THEN v_obj := v_val::text;
    ELSIF jsonb_typeof(v_val) = 'boolean' THEN v_obj := v_val::text;
    ELSIF jsonb_typeof(v_val) = 'string'  THEN
      s := v_val #>> '{}';
      IF s ~ '^[a-z][a-z0-9+.-]*:[^ ]' AND (v_d IS NULL OR v_d = '') THEN
        v_obj := '<'||s||'>';
      ELSE
        v_obj := '"'||replace(replace(replace(s,'\','\\'),'"','\"'),chr(10),'\n')||'"';
        -- declared datatype wins; xsd:string is the default and needs no tag
        IF v_d IS NOT NULL AND v_d <> 'http://www.w3.org/2001/XMLSchema#string' THEN
          v_obj := v_obj||'^^<'||v_d||'>';
        END IF;
      END IF;
    ELSE CONTINUE;
    END IF;
    v_ttl := v_ttl || '<'||p_subj||'> <'||v_key||'> '||v_obj||' .'||chr(10);
  END LOOP;
  RETURN v_ttl;
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
      'https://conceptkernel.org/ontology/v3.8/core#participant', v_participant);
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
    v_cand := ckp._body_to_ttl(p_body, p_instance_id, v_comp)
              || ckp._parent_closure_ttl(v_type, p_instance_id, v_comp);
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
    @prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    <urn:ckp:led:%s> a ckp:LedgerEntry ;
      ckp:about <%s> ; ckp:bodySha "%s" ; ckp:sig "%s" ;
      ckp:ts "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, v_sig, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_led_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: ledger entry fails ckp:LedgerEntryShape (core governance)';
  END IF;
  INSERT INTO ckp.ledger(instance_id, body_sha256, sig, prev_seq)
  VALUES (p_instance_id, v_sha, v_sig, v_prev);

  -- 4. VALIDATE the protocol's OWN proof op, then write it.
  v_prf_ttl := format($t$
    @prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
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

ALTER FUNCTION ckp._report_summary(jsonb)             OWNER TO ck_substrate;
ALTER FUNCTION ckp.validation_report_ttl(jsonb, text) OWNER TO ck_substrate;
ALTER FUNCTION ckp._body_to_ttl(jsonb, text, int)     OWNER TO ck_substrate;
ALTER FUNCTION ckp.seal(text, jsonb)                  OWNER TO ck_substrate;

-- ─────────────────────────────────────────────────────────────────────
-- P0 (pgCK#35): ckp.validate passes mode 'pgrdf' to pgrdf.validate.
--
-- It previously passed no mode, so every seal validated in 'native', and
-- native SILENTLY SKIPS sh:sparql — conforms=true, zero results, no error.
-- That is the fake-green family this wave exists to remove, sitting in the
-- seal itself.
--
-- Measured on the bench, same candidate + same composed graph, 5 runs, median:
--   native 5.12 ms   sparql 7.78 ms   pgrdf 3.72 ms
-- Mode 'pgrdf' is the FASTEST of the three, so this is not a hot-path trade.
-- Neither the v3.11 root nor the shipped v3.8 core declares sh:sparql today
-- (0 occurrences each), so it changes no current behaviour either — it removes
-- a trap that fires the first time anyone adds one.
--
-- Regression after the change: valid body ACCEPTED, bad bodySha REFUSED,
-- short sig REFUSED.

CREATE OR REPLACE FUNCTION ckp.validate(ttl text, shapes_graph_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
  scratch_id INT := 1000000000 + pg_backend_pid();
  report jsonb;
BEGIN
  PERFORM pgrdf.add_graph(scratch_id, 'urn:ckp:scratch:'||scratch_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  PERFORM pgrdf.materialize(scratch_id);
  report := pgrdf.validate(scratch_id, shapes_graph_id, 'pgrdf');
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$function$
;

ALTER FUNCTION ckp.validate(text, int) OWNER TO ck_substrate;
