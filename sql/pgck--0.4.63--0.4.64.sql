-- pgck 0.4.64 — an unattributed write is refused, never minted.
--
-- ckp.seal minted urn:ckp:participant:anon:<fresh-uuid> when no identity was
-- present: every naked-path write became a permanent fact belonging to nobody,
-- and N such seals presented as N distinct participants. 0.4.62 excluded anon
-- from quorum; this closes unattributability itself, completing the ruling
-- (ruling-1786732538387020000) that named refusal as the destination. The door
-- is unaffected — its anonymous tier is subscribe-only and never reaches seal.
-- The naked path must now name a declared identity; the dev/test bootstrap
-- names its own (svc:bench-bootstrap) as the sanctioned operator form:
-- attributed, constant, accountable — never a fresh uuid. The 39 historical
-- anon seals stand as fenced history; no new one can exist.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

-- AND: the spine projection registers <p>/instances under the SAME
-- deterministic graph id as the label trigger — two registration paths for one
-- IRI made the loser raise and the trigger's swallow hid it, silently darkening
-- the label search index (s32 caught it: governed match found 0 of 3).
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

CREATE OR REPLACE FUNCTION ckp._project_instance_spine(p_id text, p_body jsonb, p_project text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_g    bigint;
  v_subj text;
  v_ttl  text := '';
  v_key  text;
  v_val  jsonb;
  v_el   jsonb;
  v_type text := p_body->>'type';
BEGIN
  v_subj := COALESCE(NULLIF(p_body->>'@id',''), '');
  IF v_subj !~ '^[A-Za-z][A-Za-z0-9+.-]*:' THEN
    v_subj := 'urn:ckp:'||p_project||'/inst/'||ckp._slug(p_id);
  END IF;
  IF v_type IS NOT NULL AND position(':' in v_type) > 0 THEN
    v_ttl := v_ttl || format('<%s> a <%s> .%s', v_subj, v_type, chr(10));
  END IF;
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_body) LOOP
    CONTINUE WHEN v_key !~ '^(https?://|urn:)';
    IF jsonb_typeof(v_val) = 'array' THEN
      FOR v_el IN SELECT * FROM jsonb_array_elements(v_val) LOOP
        v_ttl := v_ttl || ckp._spine_triple(v_subj, v_key, v_el);
      END LOOP;
    ELSIF jsonb_typeof(v_val) IN ('string','number','boolean') THEN
      v_ttl := v_ttl || ckp._spine_triple(v_subj, v_key, v_val);
    END IF;   -- objects are payload structure, not spine
  END LOOP;
  IF v_ttl = '' THEN RETURN; END IF;
  -- 0.4.64 — SAME deterministic id as project_instance_label's trigger. Two
  -- registration paths for one IRI meant first-writer-wins: when a seal's spine
  -- projection auto-registered <p>/instances at a low id first, the trigger's
  -- deterministic add_graph raised, its swallow hid it, and the label search
  -- index silently went dark (s32: governed match found 0 of 3). One IRI, one
  -- id formula, both writers.
  v_g := 1300000000 + (abs(hashtext(format('urn:ckp:%s/instances', p_project))) % 90000000);
  PERFORM pgrdf.add_graph(v_g, format('urn:ckp:%s/instances', p_project));
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, 'urn:ckp:spine#');
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'ckp._project_instance_spine: % (instance % sealed and ledgered; the RDF mirror is behind — run wave.project to rebuild)', SQLERRM, p_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.wave_project_spine(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_proj text := ckp._project();
  v_g bigint; v_n int := 0; r record;
BEGIN
  v_g := 1300000000 + (abs(hashtext(format('urn:ckp:%s/instances', v_proj))) % 90000000);
  PERFORM pgrdf.add_graph(v_g, format('urn:ckp:%s/instances', v_proj));
  PERFORM pgrdf.clear_graph(v_g);
  FOR r IN SELECT id, body FROM ckp.instances ORDER BY ts_created LOOP
    PERFORM ckp._project_instance_spine(r.id, r.body, v_proj);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'kernel', v_proj,
    'graph', 'urn:ckp:'||v_proj||'/instances', 'projected', v_n,
    'note', 'the sealed spine is now SPARQL-visible: rdf:type + every IRI-keyed property incl. the four stamps. The fence census is the MINUS-pair over this graph — sealedAtEpoch MINUS conformsToShape.');
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
