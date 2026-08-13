-- pgck 0.4.57 — the composer honoured two spellings of intoProject and ignored
-- the most principled one.
--
-- ckp._adopted_graphs matched 'urn:ckp:<p>' and 'urn:ckp:<p>/kernel/ck' and
-- MISSED 'urn:ckp:project:<p>' — the IRI germinate_kernel itself seals as the
-- ckp:Project @id, the one a caller who reads the graph will naturally use.
-- pgck-mcp sealed an Adoption of the wave module with exactly that spelling: it
-- was judged by AdoptionShape, ledgered, proof-digested — and composed NOTHING.
-- They measured it (materialization at their epoch 5: modules [], digest
-- unchanged) and filed the surface.modules ask on pgck's kernel. pgCK's own
-- adoptions composed only because they copied A3's bare spelling: the composer
-- rewarded the accident and ignored the principle. A sealed record whose
-- declared value silently has no effect is R2's defect shape, in the composer.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

-- ALSO IN 0.4.57 — ckp.transition's re-seal is judged by the kernel that
-- produced the fact (derived from the substrate-stamped producedBy), never by
-- the ambient session project. Sealing under _project() meant an instance
-- produced by one kernel, transitioned from a session naming another, was
-- re-validated against a FOREIGN surface — invisible while the type gate was
-- fleet-wide, refused by s56 the moment it was scoped. The map lookup was
-- already project-independent; the re-seal now follows the same rule.
-- AND: ckp.bootstrap_kernel resets the engine's shmem term cache (guarded on
-- pgrdf.shmem_reset existing) — an aborted seal can leave the cache in a state
-- where a quad stores but SHACL cannot see it, refusing conformant work; every
-- negative control in the suite is an aborted seal, so each test file starts
-- clean.
CREATE OR REPLACE FUNCTION ckp._adopted_graphs(p_project text)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N text := 'https://conceptkernel.org/ontology/v3.11/core#';
BEGIN
  -- Sealed, unsuperseded Adoptions of THIS project, in seal order.
  --
  -- 0.4.57 — THE THIRD SPELLING, found by pgck-mcp the hard way. This accepted
  -- 'urn:ckp:<p>' and 'urn:ckp:<p>/kernel/ck' and MISSED 'urn:ckp:project:<p>' —
  -- which is the MOST principled form, because germinate_kernel seals exactly
  -- that IRI as the ckp:Project @id and the kernel's inProject points at it. So
  -- a caller who read the graph and used the Project's real IRI sealed an
  -- Adoption that was judged by AdoptionShape, ledgered, proof-digested — and
  -- silently composed NOTHING. Measured by pgck-mcp (adoption at their seq 159,
  -- intoEpoch 4, then a full materialization at epoch 5: modules [], digest
  -- unchanged) and filed as the surface.modules ask on this kernel. pgCK's own
  -- adoptions worked only because they copied A3's bare spelling — the composer
  -- rewarded the accident and ignored the principle. A sealed record whose
  -- declared value has no effect is R2's defect shape, inside the composer.
  RETURN COALESCE((
    SELECT array_agg(a.body->>(N||'adopts') ORDER BY a.ts_created)
    FROM ckp.instances a
    WHERE a.body->>'type' = N||'Adoption'
      AND a.body->>(N||'adopts') IS NOT NULL
      AND a.body->>(N||'intoProject') IN ('urn:ckp:'||p_project,
                                          'urn:ckp:'||p_project||'/kernel/ck',
                                          'urn:ckp:project:'||p_project)
      AND NOT EXISTS (
        SELECT 1 FROM ckp.instances s
        WHERE s.body->>'type' = N||'Supersession'
          AND s.body->>(N||'supersedes') = a.body->>'@id')
  ), ARRAY[]::text[]);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  N        text := 'urn:ckp:board/';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';
  v_body   jsonb; v_from text; v_type text; v_allowed jsonb; v_has_map boolean; v_src text;
BEGIN
  IF v_to IS NULL OR v_to !~ v_state_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  v_type := v_body->>'type';
  v_from := COALESCE(v_body->>(N||'lifecycle_state'), v_body->>'state', v_body->>(C||'lifecycle_state'), 'planned');

  -- T3 (v0.4.20, pgCK#7): does the instance's TYPE carry a sealed transition map in ANY kernel
  -- graph? Resolve project-independently — ckp:allowsTransition only exists in kernel graphs.
  v_has_map := (v_type IS NOT NULL AND v_type ~ '^[A-Za-z]' AND EXISTS (
    SELECT 1 FROM pgrdf.sparql(format($q$
      PREFIX ckp: <%s>
      SELECT ?t WHERE { GRAPH ?g { <%s> ckp:allowsTransition ?t } } LIMIT 1
    $q$, C, v_type)) j));

  IF v_has_map THEN
    -- the type's sealed map governs (wherever it lives). from must be a safe state to bind.
    v_src := 'kernel';
    IF v_from !~ v_state_re OR NOT EXISTS (
      SELECT 1 FROM pgrdf.sparql(format($q$
        PREFIX ckp: <%s>
        SELECT ?t WHERE { GRAPH ?g {
          <%s> ckp:allowsTransition ?t . ?t ckp:fromState "%s" ; ckp:toState "%s" } }
      $q$, C, v_type, v_from, v_to)) j) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'source', v_src);
    END IF;
  ELSE
    -- fallback: the global config map (back-compat).
    v_src := 'config';
    v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
    IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'allowed', v_allowed, 'source', v_src);
    END IF;
  END IF;

  v_body := v_body || jsonb_build_object(N||'lifecycle_state', v_to, 'state', v_to);
  -- 0.4.57 — THE RE-SEAL IS JUDGED BY THE KERNEL THAT PRODUCED THE FACT, never
  -- by the ambient session project. This sealed under _project(), so an
  -- instance produced by demo, transitioned from a session whose GUC named a
  -- different kernel, was re-validated against a FOREIGN surface — an M2
  -- violation (jurisdiction: whose meaning governs it). Invisible while the
  -- type gate was fleet-wide; the moment the gate was scoped (0.4.51), s56
  -- refused exactly this, which is that test doing its job one layer deeper
  -- than it was written for. The map lookup above was already
  -- project-independent; the re-seal now follows the same rule: derive the
  -- project from the substrate-stamped producedBy (unforgeable), fall back to
  -- the session only for pre-stamp rows.
  DECLARE
    v_pb   text := v_body->>(C||'producedBy');
    v_proj text;
  BEGIN
    IF v_pb IS NOT NULL AND v_pb ~ '^urn:ckp:.+/kernel/ck$' THEN
      v_proj := regexp_replace(v_pb, '^urn:ckp:(.+)/kernel/ck$', '\1');
      PERFORM set_config('ckp.project', v_proj, true);
    END IF;
    PERFORM ckp.seal(v_id, v_body);
  END;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to,
                            'source', v_src, 'verified', ckp.verify(v_id));
END;
$function$
;

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
END;
$procedure$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
