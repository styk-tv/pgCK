-- pgck 0.4.39 -> 0.4.40
--
-- v3.11-ONLY ONTOLOGY DELIVERY. Three routines stop reaching for pre-v3.11 files,
-- so `ontology/` can hold README.md + v3.11/ and nothing else.
--
-- Measured before writing this (2026-08-11, against the loaded root
-- urn:ckp:core/v3.11, digest e5f7d1e5…): ckp:Goal and ckp:Task DO NOT EXIST in
-- v3.11. Querying the root for rdfs:label over {Goal, Task, Kernel, Instance,
-- Organ} returns three rows — Instance, Kernel, Organ. The board vocabulary is
-- the adopted wave module (wave:Ticket, wave:Pass, wave:Index …), which is why
-- the pair is retired here rather than relocated.
--
-- What this does NOT do: it does not delete a file. Expiry is stated in three
-- layers — sealed withdrawal in the graph, refusal by name at the door, and only
-- then removal from disk — so that asking for a retired module returns a REASON
-- rather than a missing-file error. This migration is layer two.

-- ---------------------------------------------------------------------------
-- 1. boot reads the v3.11 root, not the legacy mirror.
--
-- This is the ONLY hard file dependency in the install path: pg_read_file here
-- is unwrapped and raises, so `ontology/core.ttl` could not be removed while
-- this default pointed at it. `/ontology/v3.11/core.ttl` is the CK-org
-- publication mirrored byte-identically (sha256 e5f7d1e5…, sidecar-verified).
-- Body otherwise carries verbatim from 0.4.39.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ckp.boot(IN p_core_ttl_path text DEFAULT '/ontology/v3.11/core.ttl'::text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE v_core INT; v_ttl TEXT; v_shapes INT;
BEGIN
  PERFORM pgrdf.shmem_reset();
  -- P0-A0 (pgCK#23): resolve the core graph BY IRI and record the id it got.
  -- Never assume an id from config.
  v_core := pgrdf.add_graph('urn:ckp:core');
  INSERT INTO ckp.config(k,v) VALUES ('core_graph_id', v_core::text)
    ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
  -- Fail loudly. An empty core graph is not a runnable state.
  SELECT count(*) INTO v_shapes FROM pgrdf.sparql(
    'PREFIX sh:<http://www.w3.org/ns/shacl#> SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a sh:NodeShape } }');
  IF v_shapes = 0 THEN
    RAISE EXCEPTION 'ckp.boot: core ontology at % loaded 0 sh:NodeShape — refusing to run with an unenforced core', p_core_ttl_path;
  END IF;
  -- Ring repair (fresh install, measured 2026-08-08): the per-graph tables this
  -- boot just created belong to the CALLING superuser, while every internal that
  -- reads them runs as ck_substrate. Re-assert the substrate floor over pgrdf.
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
  RAISE NOTICE 'ckp.boot: core graph % loaded from %, % NodeShapes', v_core, p_core_ttl_path, v_shapes;
END;
$procedure$;

-- ---------------------------------------------------------------------------
-- 2. import_module refuses the retired board pair BY NAME, with a reason.
--
-- 0.4.39 retired the five v3.8 modules and left {task, goal} known. They are now
-- retired too, which empties the known set: every module in force arrives by a
-- sealed ckp:Adoption naming its digest, never by reading a file from a mount.
-- "unknown module" is the wrong answer for a thing that was deliberately
-- withdrawn — a refusal is a result, so it names the retirement and the successor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ckp.import_module(IN p_module text, IN p_project text DEFAULT 'demo'::text, IN p_root text DEFAULT '/ontology'::text)
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
DECLARE
  -- EMPTY BY RULING. affordance/delegation/proof are declared by the v3.11 root
  -- itself; delivery/validate were cut; task/goal do not exist in v3.11 at all.
  v_known_modules text[] := ARRAY[]::text[];
  v_retired       text[] := ARRAY['affordance','delegation','proof','delivery','validate','task','goal'];
  v_core_ns text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_path text;
  v_iri  text := format('urn:ckp:%s/kernel/board', p_project);
  v_g    int;
  v_ttl  text;
  v_minted text;
BEGIN
  IF p_module = ANY (v_retired) THEN
    RAISE EXCEPTION E'ckp.import_module: module "%" is RETIRED, not missing.\n'
      'task and goal do not exist in the v3.11 root — measured against the loaded '
      'core (digest e5f7d1e5…): ckp:Goal and ckp:Task are declared by nothing. The '
      'board vocabulary is the adopted wave module: use wave:Ticket, wave:Pass and '
      'wave:Index. affordance, delegation and proof are declared by the root itself; '
      'delivery and validate were cut by ruling. A module reaches a surface only '
      'through a sealed ckp:Adoption naming its digest — never by reading % .',
      p_module, format('%s/%s.ttl', p_root, p_module);
  END IF;

  IF NOT (p_module = ANY (v_known_modules)) THEN
    RAISE EXCEPTION 'ckp.import_module: unknown module %; the known set is EMPTY by ruling. '
      'Every module in force is adopted by digest (ckp:Adoption), not imported from a mount.', p_module;
  END IF;

  -- Unreachable while the known set is empty; retained so re-opening the door
  -- cannot skip R7. An extension MUST NOT mint terms into the core namespace.
  v_path := format('%s/%s.ttl', p_root, p_module);
  v_ttl  := pg_read_file(v_path);
  SELECT string_agg(DISTINCT m[1], ', ')
    INTO v_minted
  FROM regexp_matches(v_ttl, '(?:^|[^A-Za-z0-9_])(ckp:[A-Za-z_][A-Za-z0-9_]*)\s+a\s+(?:rdfs:Class|owl:Class|owl:ObjectProperty|owl:DatatypeProperty)', 'g') AS m;
  IF v_minted IS NOT NULL THEN
    RAISE EXCEPTION E'ckp.import_module: module "%" mints term(s) into the CORE namespace (%): %\n'
      'R7 is normative — re-issue under domain naming and adopt it by digest.',
      p_module, v_core_ns, v_minted;
  END IF;
  SELECT pgrdf.add_graph(v_iri) INTO v_g;
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, v_iri || '#');
  PERFORM pgrdf.materialize(v_g);
  RAISE NOTICE 'ckp.import_module: % imported into %', p_module, v_iri;
END;
$procedure$;

-- ---------------------------------------------------------------------------
-- 3. load_kernel stops reaching for the board pair.
--
-- 0.4.39 wrapped these two CALLs in an EXCEPTION handler, so a missing file was
-- already survivable — it logged a NOTICE and continued. That made the failure
-- quiet rather than absent: every kernel load emitted a board-import warning for
-- modules that no longer exist. Removing the calls makes the silence honest.
-- Body otherwise carries verbatim from 0.4.39.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ckp.load_kernel(IN p_path text, IN p_project text DEFAULT 'demo'::text)
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
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
  -- Ring repair (#48, same pattern as ckp.boot): the kernel graph's quad table
  -- was just created owned by the CALLING superuser; the first seal's definer
  -- path reads it as ck_substrate. Re-assert the substrate floor over pgrdf.
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;
  -- No ambient board graph. task/goal are retired (see import_module above); the
  -- board is the adopted wave module, which arrives by Adoption, not by import.
END;
$procedure$;
