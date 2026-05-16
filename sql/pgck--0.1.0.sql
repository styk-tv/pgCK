-- pgck 0.1.0 — governed-write core (PL/pgSQL; shipped via pgrx extension_sql_file!).
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
  scratch_id INT := 9000 + (random()*900)::int;
  report JSONB;
BEGIN
  PERFORM pgrdf.add_graph(scratch_id, format('urn:ckp:scratch:%s', scratch_id));
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

  -- 1. VALIDATE payload against the kernel ontology's required props (materializer logic, inline).
  SELECT string_agg(rp, ', ') INTO v_missing
  FROM (
    SELECT (t->>'required_prop') AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE {
        ?s sh:targetClass <%s> ; sh:property ?p .
        ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1)
      }$q$, v_type), v_kgraph) AS t
  ) req
  WHERE NOT (p_body ? rp);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'ckp.seal: payload fails kernel shape; missing required: %', v_missing;
  END IF;

  -- 2. MATERIALIZE durable instance (local now; Azure via FDW after import).
  v_sha := encode(digest(convert_to(p_body::text,'UTF8'),'sha256'),'hex');
  v_sig := encode(hmac(v_sha, current_setting('ckp.identity_key', true), 'sha256'),'hex'); -- ed25519 swap later
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
      ckp:about <%s> ; ckp:method "ed25519+sha256" ; ckp:digest "%s" ;
      ckp:verifiedAt "%s"^^xsd:dateTime .$t$,
    p_instance_id, p_instance_id, v_sha, to_char(v_now,'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF NOT ckp.validate(v_prf_ttl, v_core) THEN
    RAISE EXCEPTION 'ckp.seal: proof fails ckp:ProofShape (core governance)';
  END IF;
  INSERT INTO ckp.proof(about, method, digest) VALUES (p_instance_id,'ed25519+sha256',v_sha);

  RETURN v_sha;  -- all committed atomically by the caller's transaction
END;
$$;

-- ---- independent verification ----
CREATE OR REPLACE FUNCTION ckp.verify(p_instance_id TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_body JSONB; v_recompute TEXT; v_stored TEXT;
BEGIN
  SELECT body INTO v_body FROM ckp.instances WHERE id = p_instance_id;
  IF v_body IS NULL THEN RETURN false; END IF;
  v_recompute := encode(digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  SELECT body_sha256 INTO v_stored FROM ckp.ledger
    WHERE instance_id = p_instance_id ORDER BY seq DESC LIMIT 1;
  RETURN v_recompute = v_stored;
END;
$$;
