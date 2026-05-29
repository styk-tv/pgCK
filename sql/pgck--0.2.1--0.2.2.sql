-- pgCK 0.2.1 -> 0.2.2 upgrade
--
-- Two object changes, both CREATE OR REPLACE (safe on a live, bootstrapped DB):
--
--  1. ckp.bootstrap_kernel() — now creates ckp.outbox + the ckp_ledger_after_insert
--     trigger INSIDE the procedure (alongside ledger/instances/proof). In 0.2.1 these
--     were install-time top-level DDL, which broke fresh CREATE EXTENSION because the
--     outbox FK / trigger referenced ckp.ledger before bootstrap_kernel had created it.
--     Existing 0.2.1 installs already have the outbox table + trigger (created top-level
--     at their 0.2.0->0.2.1 upgrade); the IF NOT EXISTS / DROP TRIGGER IF EXISTS guards
--     make this re-run a no-op for them.
--
--  2. ckp.seal() — CKF-3: resolves an optional "participant" claims object to the
--     canonical IRI urn:ckp:participant:<sub> (or urn:ckp:participant:anon:<nonce>),
--     persisted into ckp.instances.body before the body SHA so verify() stays consistent.
--
-- The trigger function ckp.ledger_to_outbox() and ckp.compute_publish_subject() are
-- unchanged from 0.2.1 and remain top-level in the base; not repeated here.

-- ---- (1) ckp.bootstrap_kernel() with outbox + trigger ----
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
  -- ckp.outbox is a core durable table alongside ledger/instances/proof
  -- (CKA-6 NATS publish queue). It MUST be created here, not as install-time
  -- top-level DDL, because its FK references ckp.ledger which is created
  -- above in this same procedure. The trigger function ckp.ledger_to_outbox()
  -- is defined top-level at install, so it exists by the time this procedure
  -- is CALLed and the trigger below can bind to it. Idempotent.
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
  DROP TRIGGER IF EXISTS ckp_ledger_after_insert ON ckp.ledger;
  CREATE TRIGGER ckp_ledger_after_insert
    AFTER INSERT ON ckp.ledger
    FOR EACH ROW EXECUTE FUNCTION ckp.ledger_to_outbox();
END;
$$;

-- ---- (2) ckp.seal() with CKF-3 participant resolution ----
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
