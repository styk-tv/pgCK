-- pgck 0.1.2 — governed-write core (PL/pgSQL; shipped via pgrx extension_sql_file!).
-- Works today against local tables; swap to postgres_fdw → Azure with no call-site change.
-- NATS bridge (embedded server + WSS client) is the Rust bgworker — see src/bgworker.rs.

CREATE SCHEMA IF NOT EXISTS ckp;

-- Core ontology graph id is fixed; kernel graph id is per-pod (default 2).
-- core.ttl is loaded by the entrypoint (psql) right after CREATE EXTENSION,
-- because parse_turtle needs the file contents at runtime.
CREATE TABLE IF NOT EXISTS ckp.config (
  k TEXT PRIMARY KEY, v TEXT NOT NULL
);
INSERT INTO ckp.config(k,v) VALUES
  ('core_graph_id','1'), ('kernel_graph_id','2')
ON CONFLICT (k) DO NOTHING;

-- ---- durable tables (local now; foreign tables → Azure after FDW import) ----
-- ckp.bootstrap_kernel is idempotent and migration-aware (ALTER, not blind CREATE).
CREATE OR REPLACE PROCEDURE ckp.bootstrap_kernel()
LANGUAGE plpgsql AS $$
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
END;
$$;

CREATE OR REPLACE PROCEDURE ckp.boot(p_core_ttl_path TEXT DEFAULT '/ontology/core.ttl')
LANGUAGE plpgsql AS $$
DECLARE v_core INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
        v_ttl  TEXT;
BEGIN
  -- Evict any poisoned entries from pgRDF's process-wide shmem
  -- dictionary cache before (re)loading. A prior corrupted ingest in a
  -- persistent PGDATA can leave fingerprint->bad-dict-id slots that
  -- short-circuit term interning, making pgrdf.sparql / SHACL validation
  -- silently match nothing (terms resolve to hashes). boot is the
  -- prepare-substrate step, so the reset belongs here and runs first.
  PERFORM pgrdf.shmem_reset();
  PERFORM pgrdf.add_graph(v_core, 'urn:ckp:core');
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
END;
$$;

CREATE OR REPLACE PROCEDURE ckp.load_kernel(p_path TEXT, p_project TEXT DEFAULT 'demo')
LANGUAGE plpgsql AS $$
DECLARE v_k INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
        v_iri TEXT := format('urn:ckp:%s/kernel/ck', p_project);
        v_ttl TEXT;
BEGIN
  PERFORM pgrdf.add_graph(v_k, v_iri);
  PERFORM pgrdf.clear_graph(v_k);
  v_ttl := pg_read_file(p_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_k, 'urn:ckp:kernel#');
  PERFORM pgrdf.materialize(v_k);
END;
$$;

-- ---- SHACL gate: validate arbitrary turtle against a shapes graph ----
-- Loads `ttl` into a scratch graph, validates vs shapes_graph_id, returns conforms.
CREATE OR REPLACE FUNCTION ckp.validate(ttl TEXT, shapes_graph_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
  scratch_id INT := 1000000000 + pg_backend_pid();
  report JSONB;
BEGIN
  PERFORM pgrdf.add_graph(scratch_id, format('urn:ckp:scratch:%s', scratch_id));
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  report := pgrdf.validate(scratch_id, shapes_graph_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$$;

-- ---- the governed write path: validate → instance → ledger → proof ----
-- One transaction. Each protocol operation is core-shape-validated before it commits.
CREATE OR REPLACE FUNCTION ckp.seal(p_instance_id TEXT, p_body JSONB)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_core   INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  v_kgraph INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
  v_identity_key TEXT := COALESCE(
    NULLIF(current_setting('ckp.identity_key', true), ''),
    (SELECT v FROM ckp.config WHERE k='identity_key')
  );
  v_type   TEXT := p_body->>'type';
  v_missing TEXT;
  v_sha    TEXT;
  v_sig    TEXT;
  v_prev   BIGINT;
  v_now    TIMESTAMPTZ := now();
  v_led_ttl TEXT;
  v_prf_ttl TEXT;
BEGIN
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'ckp.seal: body has no "type"';
  END IF;

  IF v_identity_key IS NULL OR v_identity_key = '' THEN
    RAISE EXCEPTION 'ckp.seal: no identity key configured';
  END IF;

  -- 1. VALIDATE payload against the kernel ontology's required props (materializer logic, inline).
  SELECT string_agg(rp, ', ') INTO v_missing
  FROM (
    SELECT j->>'required_prop' AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE {
        GRAPH <urn:ckp:%s/kernel/ck> {
          ?s sh:targetClass <%s> ; sh:property ?p .
          ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1) } }
    $q$, current_setting('ckp.project', true), v_type)) AS j
  ) req
  WHERE NOT (p_body ? rp);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'ckp.seal: payload fails kernel shape; missing required: %', v_missing;
  END IF;

  -- 2. MATERIALIZE durable instance (local now; Azure via FDW after import).
  v_sha := encode(digest(convert_to(p_body::text,'UTF8'),'sha256'),'hex');
  v_sig := encode(hmac(v_sha, v_identity_key, 'sha256'),'hex');
  SELECT max(seq) INTO v_prev FROM ckp.ledger;

  INSERT INTO ckp.instances(id, body) VALUES (p_instance_id, p_body)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, ts_updated = v_now;

  -- 3. VALIDATE the protocol's OWN ledger op against the CORE shape, then write it.
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

  -- 4. VALIDATE the protocol's OWN proof op against the CORE shape, then write it.
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

  RETURN v_sha;  -- all committed atomically by the caller's transaction
END;
$$;

-- ---- independent verification ----
CREATE OR REPLACE FUNCTION ckp.verify(p_instance_id TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
  v_body JSONB;
  v_identity_key TEXT := COALESCE(
    NULLIF(current_setting('ckp.identity_key', true), ''),
    (SELECT v FROM ckp.config WHERE k='identity_key')
  );
  v_recompute TEXT;
  v_ledger_seq BIGINT;
  v_ledger_sha TEXT;
  v_ledger_sig TEXT;
  v_prev_seq BIGINT;
  v_expected_prev BIGINT;
  v_proof_method TEXT;
  v_proof_digest TEXT;
  v_expected_sig TEXT;
BEGIN
  IF v_identity_key IS NULL OR v_identity_key = '' THEN
    RETURN false;
  END IF;

  SELECT body INTO v_body FROM ckp.instances WHERE id = p_instance_id;
  IF v_body IS NULL THEN
    RETURN false;
  END IF;

  SELECT seq, body_sha256, sig, prev_seq
  INTO v_ledger_seq, v_ledger_sha, v_ledger_sig, v_prev_seq
  FROM ckp.ledger
  WHERE instance_id = p_instance_id
  ORDER BY seq DESC
  LIMIT 1;

  SELECT method, digest
  INTO v_proof_method, v_proof_digest
  FROM ckp.proof
  WHERE about = p_instance_id
  ORDER BY id DESC
  LIMIT 1;

  IF v_ledger_seq IS NULL
     OR v_ledger_sha IS NULL
     OR v_ledger_sig IS NULL
     OR v_proof_method IS NULL
     OR v_proof_digest IS NULL THEN
    RETURN false;
  END IF;

  v_recompute := encode(digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  v_expected_sig := encode(hmac(v_recompute, v_identity_key, 'sha256'),'hex');
  SELECT max(seq) INTO v_expected_prev FROM ckp.ledger WHERE seq < v_ledger_seq;

  RETURN v_prev_seq IS NOT DISTINCT FROM v_expected_prev
     AND v_proof_method = 'hmac+sha256'
     AND v_recompute = v_ledger_sha
     AND v_ledger_sha = v_proof_digest
     AND v_ledger_sig = v_expected_sig;
END;
$$;
-- pgCK v0.1.2 → v0.2.0 upgrade DRAFT
--
-- Status:  DRAFT — not yet wired into the extension control file. The Rust
--          side that fires `event.kernel.Dictionary.v_bumped` on intern, and
--          the SHACL-gate hook inside ckp.seal(), still need implementation.
-- Source:  _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md (companion ontology)
--          _WIP/SPEC.PGCK.NATS-CK-LIB-JS-ALIGNMENT.v0.1.md §3, §6 (NATS surface)
--
-- This file is idempotent: re-running it on a v0.2 schema is a no-op. It does
-- NOT alter ckp.boot(), ckp.seal(), or ckp.load_kernel() yet — those changes
-- live in the same upgrade script when the Rust-side hooks ship.

-- ============================================================================
-- §1. ckp.dictionary — IRI ↔ uint32 handle table (per-project dictionary)
-- ============================================================================
-- Spec ref: NATS-CK-LIB-JS-ALIGNMENT.v0.1 §3.2
-- Wire form: uint32 on MessagePack envelopes; bigint here gives headroom.

CREATE TABLE IF NOT EXISTS ckp.dictionary (
  handle    bigint      PRIMARY KEY,
  iri       text        NOT NULL UNIQUE,
  added_at  timestamptz NOT NULL DEFAULT now(),
  v         bigint      NOT NULL
);

CREATE INDEX IF NOT EXISTS dictionary_v_idx ON ckp.dictionary (v);

CREATE SEQUENCE IF NOT EXISTS ckp.dictionary_handle_seq START 1;
CREATE SEQUENCE IF NOT EXISTS ckp.dictionary_v_seq      START 1;

-- get-or-create: returns the existing handle for an IRI, or allocates the next
-- handle and bumps the per-project dictionary version. The Rust side observes
-- new rows via LISTEN/NOTIFY on the channel below and emits the matching
-- event.kernel.Dictionary.v_bumped broadcast on NATS.
CREATE OR REPLACE FUNCTION ckp.dict_intern(p_iri text)
RETURNS TABLE (handle bigint, v bigint) LANGUAGE plpgsql AS $$
DECLARE
  v_handle bigint;
  v_v      bigint;
BEGIN
  IF p_iri IS NULL OR length(p_iri) = 0 THEN
    RAISE EXCEPTION 'ckp.dict_intern: iri must be non-empty';
  END IF;

  SELECT d.handle, d.v INTO v_handle, v_v
  FROM ckp.dictionary d WHERE d.iri = p_iri;

  IF v_handle IS NOT NULL THEN
    RETURN QUERY SELECT v_handle, v_v;
    RETURN;
  END IF;

  v_handle := nextval('ckp.dictionary_handle_seq');
  v_v      := nextval('ckp.dictionary_v_seq');

  INSERT INTO ckp.dictionary (handle, iri, v)
  VALUES (v_handle, p_iri, v_v);

  -- Hand-off to the Rust bgworker: NATS publisher LISTENs on this channel and
  -- emits event.kernel.Dictionary.v_bumped { from: v-1, to: v, delta: [...] }
  PERFORM pg_notify(
    'ckp_dict_v_bumped',
    json_build_object('handle', v_handle, 'iri', p_iri, 'v', v_v)::text
  );

  RETURN QUERY SELECT v_handle, v_v;
END;
$$;

COMMENT ON TABLE  ckp.dictionary       IS 'Per-project IRI→handle table for binary wire codec. NATS-CK-LIB-JS-ALIGNMENT §3.';
COMMENT ON FUNCTION ckp.dict_intern(text) IS 'Get-or-create handle for IRI; bumps version + fires pg_notify("ckp_dict_v_bumped") on allocation.';

-- ============================================================================
-- §2. URN normalisation helper (companion §4.3)
-- ============================================================================
-- Used at projection time inside ckp.seal() to canonicalise raw caller ids
-- before minting the entity URN. Defined here so the Rust seal-hook can call
-- it via SPI.

CREATE OR REPLACE FUNCTION ckp.urn_normalise(p_raw text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(lower(trim(coalesce(p_raw, ''))), '[^a-z0-9-]+', '-', 'g');
$$;

COMMENT ON FUNCTION ckp.urn_normalise(text) IS 'Normalise raw id to URN segment: lower(trim()), non-[a-z0-9-] runs collapsed to "-". TASK-GOAL-KERNEL-RDF §4.3.';

-- ============================================================================
-- §3. ckp.import_module(p_module, p_project) — load split ontology modules
-- ============================================================================
-- Spec ref: TASK-GOAL-KERNEL-RDF.v0.1 §3.3
-- Loads ontology/<module>.ttl into the project board graph
-- urn:ckp:<project>/kernel/board. Modules: task, goal, affordance, delegation,
-- delivery, proof, validate. Idempotent: re-loading a module clears its
-- previous version from the same graph before re-parsing.

CREATE OR REPLACE PROCEDURE ckp.import_module(
  p_module  text,
  p_project text DEFAULT 'demo',
  p_root    text DEFAULT '/ontology'
)
LANGUAGE plpgsql AS $$
DECLARE
  v_known_modules text[] := ARRAY[
    'task', 'goal', 'affordance', 'delegation',
    'delivery', 'proof', 'validate'
  ];
  v_path text;
  v_iri  text := format('urn:ckp:%s/kernel/board', p_project);
  v_g    int;
  v_ttl  text;
BEGIN
  IF NOT (p_module = ANY (v_known_modules)) THEN
    RAISE EXCEPTION 'ckp.import_module: unknown module %; known: %', p_module, v_known_modules;
  END IF;

  v_path := format('%s/%s.ttl', p_root, p_module);

  -- One board graph per project; allocate once (pgrdf.add_graph is get-or-create on IRI).
  SELECT pgrdf.add_graph(v_iri) INTO v_g;

  -- Idempotent re-load: parse the module into the board graph. parse_turtle
  -- with same subjects is additive in pgRDF; for true idempotence the Rust
  -- side may want to clear the module's own triples first. Leaving as-is in
  -- the draft until the seal-hook implementation lands.
  v_ttl := pg_read_file(v_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, format('urn:ckp:%s/module/%s#', p_project, p_module));
  PERFORM pgrdf.materialize(v_g);
END;
$$;

COMMENT ON PROCEDURE ckp.import_module(text, text, text) IS 'Load ontology/<module>.ttl into urn:ckp:<project>/kernel/board. TASK-GOAL-KERNEL-RDF §3.3.';

-- ============================================================================
-- §4. ckp.shapes_self_test(p_project) — guard against stale ontology mounts
-- ============================================================================
-- Spec ref: pgRDF NOTIFY-RESPONSE (2026-05-28) — "optional pgCK hardening".
-- Background: a stale /ontology/task.ttl in the container (pre-shape revision)
-- caused vacuous SHACL conformance because no shape targets ckp:Task at all.
-- The validator was right; the file was old. This self-test asserts that the
-- expected shapes are present in the project board graph before any ckp.seal()
-- call relies on the gate.
--
-- Raises EXCEPTION if any expected shape is missing — wire into ckp.boot() or
-- the bgworker startup so a bad mount fails fast rather than silently accepting
-- malformed seals.

CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text DEFAULT 'demo')
RETURNS TABLE (shape_class text, target_class text, present boolean)
LANGUAGE plpgsql AS $$
DECLARE
  v_board_iri text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g   bigint := pgrdf.graph_id(v_board_iri);
  v_q         text;
  v_row       record;
  v_missing   text[] := ARRAY[]::text[];
BEGIN
  IF v_board_g IS NULL THEN
    RAISE EXCEPTION 'ckp.shapes_self_test: project board graph % not present; call ckp.import_module(''task'', %s) and ckp.import_module(''goal'', %s) first',
      v_board_iri, quote_literal(p_project), quote_literal(p_project);
  END IF;

  FOR v_row IN
    SELECT * FROM (VALUES
      ('ckp:TaskShape', 'ckp:Task'),
      ('ckp:GoalShape', 'ckp:Goal')
    ) AS expected(shape, target)
  LOOP
    v_q := format(
      'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
       PREFIX sh:  <http://www.w3.org/ns/shacl#>
       PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
       ASK FROM <%s>
       WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass %s }',
      v_board_iri, v_row.target);

    shape_class  := v_row.shape;
    target_class := v_row.target;
    SELECT (j->>'boolean')::boolean INTO present
      FROM pgrdf.sparql(v_q) j LIMIT 1;
    present := coalesce(present, false);
    IF NOT present THEN
      v_missing := array_append(v_missing, v_row.shape);
    END IF;
    RETURN NEXT;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'ckp.shapes_self_test: missing % shape(s) in %; check /ontology mount is current',
      v_missing, v_board_iri;
  END IF;
END;
$$;

COMMENT ON FUNCTION ckp.shapes_self_test(text) IS 'Assert TaskShape and GoalShape are loaded in the project board graph. Raises EXCEPTION if missing — guards ckp.seal() SHACL gate against stale ontology mounts.';

-- ============================================================================
-- §5. Outstanding wiring (NOT in this draft)
-- ============================================================================
-- The following changes still need to land before v0.2 is a complete patch:
--
--   a) ckp.boot()/ckp.load_kernel(): optionally call
--      ckp.import_module('task',  current_project)
--      ckp.import_module('goal',  current_project)
--      so every project comes up with the board ontology in place. Today's
--      load_kernel signature takes a single file path; v0.2 may grow a sibling
--      variant ckp.load_board(p_project) that fans the modules out.
--
--   b) ckp.seal(): after the JSONB body and ledger row are committed, project
--      the link triples into the board graph (companion §4) and run a SHACL
--      gate against ckp:TaskShape / ckp:GoalShape (companion §5). On
--      violation, rollback the seal transaction.
--
--   c) Rust bgworker LISTEN on 'ckp_dict_v_bumped' and publish
--      event.kernel.Dictionary.v_bumped on NATS.
--
--   d) seq stamping in the NATS publisher: copy ckp.ledger.id into both the
--      v1.3 binary envelope and a Trace-Id-adjacent header on v1.2 publishes.
--
-- These items are tracked in
--   _WIP/SPEC.PGCK.NATS-CK-LIB-JS-ALIGNMENT.v0.1.md §8.

-- ============================================================================
-- §6. CKB-5 — project Task/Goal link triples on every governed seal
-- ============================================================================
-- Spec: _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §4 (Light projection on seal).
-- For each sealed Task body: project `<urn> a ckp:Task ; ckp:part_of_goal …;
-- ckp:target_kernel … .` into urn:ckp:<project>/kernel/board (+3 quads).
-- For each sealed Goal body: project `<urn> a ckp:Goal ; rdfs:label … .` (+2 quads).
-- Other instance classes are skipped (no projection in v0.1).

CREATE OR REPLACE FUNCTION ckp.project_links(
  p_project text,
  p_instance_id text,
  p_body jsonb
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_type        text := p_body->>'type';
  v_short_type  text;
  v_board_iri   text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g     bigint;
  v_subject     text;
  v_id          text;
  v_goal_id     text;
  v_kernel      text;
  v_label       text;
  v_ttl         text;
  v_added       bigint := 0;
BEGIN
  IF v_type ILIKE '%/Task' OR v_type = 'ckp:Task' THEN
    v_short_type := 'Task';
  ELSIF v_type ILIKE '%/Goal' OR v_type = 'ckp:Goal' THEN
    v_short_type := 'Goal';
  ELSE
    RETURN 0;
  END IF;

  v_board_g := pgrdf.add_graph(v_board_iri);

  IF v_short_type = 'Task' THEN
    v_id      := p_body->>'https://conceptkernel.org/ontology/v3.7/task_id';
    v_goal_id := p_body->>'https://conceptkernel.org/ontology/v3.7/part_of_goal';
    v_kernel  := p_body->>'https://conceptkernel.org/ontology/v3.7/target_kernel';

    -- Missing link predicates: skip projection; CKB-4 SHACL gate will surface
    -- a richer rejection once it lands. Today the seal still succeeds.
    IF v_id IS NULL OR v_goal_id IS NULL OR v_kernel IS NULL THEN
      RETURN 0;
    END IF;

    v_subject := 'ckp://Task#' || ckp.urn_normalise(v_id);

    v_ttl := format(
      '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '<%s> a ckp:Task ; '
      || 'ckp:part_of_goal  <ckp://Goal#%s> ; '
      || 'ckp:target_kernel <ckp://Kernel#%s> .',
      v_subject,
      ckp.urn_normalise(v_goal_id),
      ckp.urn_normalise(v_kernel));

    v_added := pgrdf.parse_turtle(v_ttl, v_board_g, 'urn:ckp:projection#');

  ELSIF v_short_type = 'Goal' THEN
    v_id    := p_body->>'https://conceptkernel.org/ontology/v3.7/goal_id';
    v_label := p_body->>'https://conceptkernel.org/ontology/v3.7/title';

    IF v_id IS NULL THEN
      RETURN 0;
    END IF;

    v_subject := 'ckp://Goal#' || ckp.urn_normalise(v_id);

    v_ttl := format(
      '@prefix ckp:  <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> . '
      || '<%s> a ckp:Goal ; rdfs:label "%s" .',
      v_subject,
      COALESCE(v_label, v_id));

    v_added := pgrdf.parse_turtle(v_ttl, v_board_g, 'urn:ckp:projection#');
  END IF;

  RETURN v_added::int;
END;
$$;

COMMENT ON FUNCTION ckp.project_links(text, text, jsonb) IS
  'CKB-5: project link triples for Task/Goal instances into the project board graph. Returns quad count added.';

-- ============================================================================
-- §7. CKB-5 — hook ckp.project_links() into ckp.seal()
-- ============================================================================
-- The hook is appended to the existing 4-step seal pipeline (validate / write
-- instance / write ledger / write proof). On Task or Goal bodies, link triples
-- materialise into the project board graph alongside the JSONB row.
-- CKB-4 (SHACL gate that rolls back on conforms=false) lands in a later release.

CREATE OR REPLACE FUNCTION ckp.seal(p_instance_id TEXT, p_body JSONB)
RETURNS TEXT LANGUAGE plpgsql AS $$
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
BEGIN
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'ckp.seal: body has no "type"';
  END IF;
  IF v_identity_key IS NULL OR v_identity_key = '' THEN
    RAISE EXCEPTION 'ckp.seal: no identity key configured';
  END IF;

  -- 1. VALIDATE payload against the kernel ontology's required props.
  SELECT string_agg(rp, ', ') INTO v_missing
  FROM (
    SELECT j->>'required_prop' AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE {
        GRAPH <urn:ckp:%s/kernel/ck> {
          ?s sh:targetClass <%s> ; sh:property ?p .
          ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1) } }
    $q$, v_project, v_type)) AS j
  ) req
  WHERE NOT (p_body ? rp);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'ckp.seal: payload fails kernel shape; missing required: %', v_missing;
  END IF;

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
$$;

-- ============================================================================
-- §8. CKB-3 — ckp.load_kernel() auto-imports the task + goal modules
-- ============================================================================
-- Spec: _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §3.3.
-- After loading the kernel/ck graph from p_path, also pull the split Task and
-- Goal ontology modules into the project board graph so seal-time projection
-- (CKB-5) has a populated shapes graph to validate against (CKB-4 follow-up).

CREATE OR REPLACE PROCEDURE ckp.load_kernel(p_path TEXT, p_project TEXT DEFAULT 'demo')
LANGUAGE plpgsql AS $$
DECLARE
  v_k   INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
  v_iri TEXT := format('urn:ckp:%s/kernel/ck', p_project);
  v_ttl TEXT;
BEGIN
  PERFORM pgrdf.add_graph(v_k, v_iri);
  PERFORM pgrdf.clear_graph(v_k);
  v_ttl := pg_read_file(p_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_k, 'urn:ckp:kernel#');
  PERFORM pgrdf.materialize(v_k);

  -- CKB-3: ambient board graph for the project — task + goal modules.
  -- Best-effort: a missing ontology file (e.g. stale container mount) raises;
  -- callers that need a hard guarantee should set up the mount before load.
  BEGIN
    CALL ckp.import_module('task', p_project);
    CALL ckp.import_module('goal', p_project);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'ckp.load_kernel: board module import failed (continuing): %', SQLERRM;
  END;
END;
$$;
-- pgCK 0.1.7 -> 0.1.8 upgrade
-- CKB-4: SHACL gate inside ckp.seal() — projection now scratches new triples
-- into a private graph, validates against the project board's shapes, and
-- ROLLS BACK the whole seal transaction (RAISE EXCEPTION) on conforms=false.
-- Pre-flight asserts ckp.shapes_self_test(project) so stale ontology mounts
-- fail fast rather than silently passing a vacuous SHACL check.
-- Spec: _WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §5.

CREATE OR REPLACE FUNCTION ckp.project_links(
  p_project text,
  p_instance_id text,
  p_body jsonb
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_type        text := p_body->>'type';
  v_short_type  text;
  v_board_iri   text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g     bigint;
  v_scratch_iri text;
  v_scratch_g   bigint;
  v_id          text;
  v_goal_id     text;
  v_kernel      text;
  v_label       text;
  v_subject     text;
  v_ttl         text;
  v_validation  jsonb;
  v_results     jsonb;
  v_added       bigint := 0;
BEGIN
  -- Class detection: only Task and Goal project link triples in v0.1.
  IF v_type ILIKE '%/Task' OR v_type = 'ckp:Task' THEN
    v_short_type := 'Task';
  ELSIF v_type ILIKE '%/Goal' OR v_type = 'ckp:Goal' THEN
    v_short_type := 'Goal';
  ELSE
    RETURN 0;
  END IF;

  -- Build the Turtle that represents this instance's link triples.
  IF v_short_type = 'Task' THEN
    v_id      := p_body->>'https://conceptkernel.org/ontology/v3.7/task_id';
    v_goal_id := p_body->>'https://conceptkernel.org/ontology/v3.7/part_of_goal';
    v_kernel  := p_body->>'https://conceptkernel.org/ontology/v3.7/target_kernel';

    -- Bodies missing any required link field reach the SHACL gate below
    -- with an empty/partial scratch graph — the gate catches them and
    -- rolls back the seal. That keeps the rejection path single-sourced.
    v_subject := 'ckp://Task#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '<%s> a ckp:Task',
      v_subject);

    IF v_goal_id IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:part_of_goal <ckp://Goal#%s>',
        ckp.urn_normalise(v_goal_id));
    END IF;
    IF v_kernel IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; ckp:target_kernel <ckp://Kernel#%s>',
        ckp.urn_normalise(v_kernel));
    END IF;
    v_ttl := v_ttl || ' .';

  ELSIF v_short_type = 'Goal' THEN
    v_id    := p_body->>'https://conceptkernel.org/ontology/v3.7/goal_id';
    v_label := p_body->>'https://conceptkernel.org/ontology/v3.7/title';

    v_subject := 'ckp://Goal#' || ckp.urn_normalise(COALESCE(v_id, p_instance_id));

    v_ttl := format(
      '@prefix ckp:  <https://conceptkernel.org/ontology/v3.8/core#> . '
      || '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> . '
      || '<%s> a ckp:Goal',
      v_subject);

    IF v_label IS NOT NULL THEN
      v_ttl := v_ttl || format(
        ' ; rdfs:label "%s"',
        replace(v_label, '"', '\"'));
    END IF;
    v_ttl := v_ttl || ' .';
  END IF;

  -- CKB-4 pre-flight: refuse to validate if the project board's shapes
  -- are missing (stale /ontology/ mount, project never imported the
  -- modules, etc.). shapes_self_test RAISES on missing shape — propagate.
  PERFORM ckp.shapes_self_test(p_project);

  -- Project into a private scratch graph so the gate decides whether the
  -- triples ever land in the board. add_graph is get-or-create; clear
  -- before parse so a duplicate seal (same id) doesn't pollute.
  v_board_g     := pgrdf.add_graph(v_board_iri);
  v_scratch_iri := format('urn:ckp:%s/seal-scratch/%s', p_project, p_instance_id);
  v_scratch_g   := pgrdf.add_graph(v_scratch_iri);
  PERFORM pgrdf.clear_graph(v_scratch_g);
  PERFORM pgrdf.parse_turtle(v_ttl, v_scratch_g, 'urn:ckp:projection#');

  -- SHACL gate: validate scratch against the board's shapes. Native mode
  -- (pgrdf 0.5.1) is sufficient — see _WIP/NOTIFIES.pgRDF.0.5.1.shacl-
  -- mincount-permissive-RESPONSE.md for the verified semantics.
  v_validation := pgrdf.validate(v_scratch_g, v_board_g);

  IF NOT (v_validation->>'conforms')::boolean THEN
    v_results := v_validation->'results';
    PERFORM pgrdf.drop_graph(v_scratch_g);
    RAISE EXCEPTION 'ckp.seal: SHACL gate rejected % % — % violation(s); first: %',
      v_short_type,
      p_instance_id,
      jsonb_array_length(v_results),
      v_results->0->>'sourceConstraintComponent';
  END IF;

  -- Validation passed: commit the same Turtle into the board graph and
  -- discard the scratch.
  v_added := pgrdf.parse_turtle(v_ttl, v_board_g, 'urn:ckp:projection#');
  PERFORM pgrdf.drop_graph(v_scratch_g);

  RETURN v_added::int;
END;
$$;

COMMENT ON FUNCTION ckp.project_links(text, text, jsonb) IS
  'CKB-4/CKB-5: validate-then-commit projection of Task/Goal link triples. RAISES on SHACL non-conformance (rolls back caller seal).';

-- ============================================================================
-- §2. CKB-4 — fix ckp.shapes_self_test ASK result parsing
-- ============================================================================
-- pgrdf.sparql returns ASK results as `{"_ask": "true"}` (string), not
-- `{"boolean": true}`. The original (v0.1.7) self-test parsed the wrong key,
-- so it always reported shapes as missing even when they were present —
-- masking the real CKB-4 gate. This replacement reads `_ask` correctly.

CREATE OR REPLACE FUNCTION ckp.shapes_self_test(p_project text DEFAULT 'demo')
RETURNS TABLE (shape_class text, target_class text, present boolean)
LANGUAGE plpgsql AS $$
DECLARE
  v_board_iri text := format('urn:ckp:%s/kernel/board', p_project);
  v_board_g   bigint := pgrdf.graph_id(v_board_iri);
  v_q         text;
  v_row       record;
  v_ask       text;
  v_missing   text[] := ARRAY[]::text[];
BEGIN
  IF v_board_g IS NULL THEN
    RAISE EXCEPTION 'ckp.shapes_self_test: project board graph % not present; call ckp.import_module(''task'', %s) and ckp.import_module(''goal'', %s) first',
      v_board_iri, quote_literal(p_project), quote_literal(p_project);
  END IF;

  FOR v_row IN
    SELECT * FROM (VALUES
      ('ckp:TaskShape', 'ckp:Task'),
      ('ckp:GoalShape', 'ckp:Goal')
    ) AS expected(shape, target)
  LOOP
    v_q := format(
      'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
       PREFIX sh:  <http://www.w3.org/ns/shacl#>
       PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
       ASK FROM <%s>
       WHERE { ?s rdf:type sh:NodeShape ; sh:targetClass %s }',
      v_board_iri, v_row.target);

    shape_class  := v_row.shape;
    target_class := v_row.target;
    SELECT j->>'_ask' INTO v_ask FROM pgrdf.sparql(v_q) j LIMIT 1;
    present := COALESCE(v_ask = 'true', false);
    IF NOT present THEN
      v_missing := array_append(v_missing, v_row.shape);
    END IF;
    RETURN NEXT;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION
      'ckp.shapes_self_test: missing % shape(s) in %; check /ontology mount is current',
      v_missing, v_board_iri;
  END IF;
END;
$$;
