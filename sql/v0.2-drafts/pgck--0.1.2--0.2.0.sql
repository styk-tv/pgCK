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
