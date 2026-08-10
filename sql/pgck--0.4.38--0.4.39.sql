-- pgck 0.4.38 -> 0.4.39 — C: the namespace rule becomes structural at the import
-- door, and the five superseded v3.8 modules are retired.
--
-- MEASURED FIRST, AND IT RESIZES THE PROBLEM (2026-08-10, live bench). The loaded
-- urn:ckp:core is BYTE-IDENTICAL to the published root (e5f7d1e5…), zero instances
-- and zero quads carry a v3.7 predicate, and no board graph exists.
--
-- MORE IMPORTANTLY: NOTHING v3.8 CAN REACH THE GATE, BY THE LOCKED DEFINITION.
-- Since 0.4.35 the enforcement surface has exactly three inlets — the epsilon-0
-- core, urn:ckp:<project>/kernel/ck, and the graph of every SEALED unsuperseded
-- Adoption. ckp.import_module writes to urn:ckp:<project>/kernel/board, which is
-- none of them, and no Adoption names a v3.8 module (measured: 0). So adoption-
-- derived composition already excludes the v3.8 modules structurally. This change
-- is HYGIENE AND DEFENCE IN DEPTH, not the closure of an open hole — stated plainly
-- because claiming otherwise would be exactly the decorative-protection failure the
-- contract's threat table names.
--
-- WHAT IS ACTUALLY WRONG WITH THE SEVEN FILES:
--   affordance, delegation, proof  declare ckp:Affordance / ckp:Delegation /
--                                  ckp:Proof at the v3.8 namespace — terms the
--                                  v3.11 root now declares itself. Dead weight, and
--                                  a trap for anyone grepping v3.8 to find live use.
--   delivery, validate             declare ckp:Delivery / ckp:Validation, both CUT
--                                  by ruling (§8.2: Delivery folds into Execution +
--                                  outTopic; the validation contract is
--                                  sh:ValidationReport, which core already ranges).
--   task, goal                     mint ckp:Task / ckp:Goal INTO the v3.11 core
--                                  namespace. This one is a real correctness defect
--                                  even though it cannot reach the gate: a project's
--                                  board graph would carry declarations the published
--                                  root does not make, so anything reading that graph
--                                  as authoritative reads a false core. R7 is
--                                  normative regardless of which graph it lands in.
--
-- WHAT THIS DOES, AND DELIBERATELY DOES NOT DO. The five superseded modules are
-- retired outright: their terms are either in the root or ruled out, so there is
-- nothing to migrate. task and goal are NOT deleted and their destination is NOT
-- decided here — moving them changes the board verbs a consumer calls, which is not
-- a call to make inside a namespace fix. Instead the RULE is enforced at the door:
-- import_module refuses any module whose file declares a term in the core namespace,
-- naming the rule and the offending terms. The violation cannot ship while the
-- destination is still open, and the refusal is loud rather than silent.
--
-- This is the same shape as every other fix this line: the gate refuses, the reason
-- is named, and the thing that cannot yet be decided is declared rather than guessed.

CREATE OR REPLACE PROCEDURE ckp.import_module(IN p_module text, IN p_project text DEFAULT 'demo'::text, IN p_root text DEFAULT '/ontology'::text)
 LANGUAGE plpgsql
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $procedure$
DECLARE
  -- The five v3.8 modules are RETIRED (see header): affordance, delegation and
  -- proof are superseded by the root's own declarations; delivery and validate
  -- were cut by ruling. Only the board pair remains known, and it must still pass
  -- the namespace guard below.
  v_known_modules text[] := ARRAY['task', 'goal'];
  v_core_ns text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_path text;
  v_iri  text := format('urn:ckp:%s/kernel/board', p_project);
  v_g    int;
  v_ttl  text;
  v_minted text;
BEGIN
  IF NOT (p_module = ANY (v_known_modules)) THEN
    RAISE EXCEPTION 'ckp.import_module: unknown module %; known: %. The v3.8 modules '
      '(affordance, delegation, delivery, proof, validate) are RETIRED — their terms are '
      'either declared by the v3.11 root itself or were cut by ruling.', p_module, v_known_modules;
  END IF;

  v_path := format('%s/%s.ttl', p_root, p_module);
  v_ttl  := pg_read_file(v_path);

  -- R7, NORMATIVE, enforced at the door: an extension MUST NOT mint terms into the
  -- core namespace. Checked on the FILE TEXT before a single triple is parsed, so a
  -- violating module can never reach a project board graph. E3 — seven
  -- undeclared predicates live in the core namespace — is the defect this prevents.
  SELECT string_agg(DISTINCT m[1], ', ')
    INTO v_minted
  FROM regexp_matches(v_ttl, '(?:^|[^A-Za-z0-9_])(ckp:[A-Za-z_][A-Za-z0-9_]*)\s+a\s+(?:rdfs:Class|owl:Class|owl:ObjectProperty|owl:DatatypeProperty|sh:NodeShape)', 'g') m;
  IF v_minted IS NOT NULL THEN
    RAISE EXCEPTION E'ckp.import_module: module "%" mints term(s) into the CORE namespace (%): %\n'
      'R7 is normative — an extension MUST NOT mint terms into the core namespace, because a '
      'project surface would then carry declarations the published root does not make, and its '
      'digest claim would be false. Re-issue the module under domain naming '
      '(urn:ckp:<project>/type|prop|shape/<Name>) or its own module namespace, then adopt it '
      'by digest like any other module.', p_module, v_core_ns, v_minted;
  END IF;

  -- One board graph per project; allocate once (pgrdf.add_graph is get-or-create on IRI).
  SELECT pgrdf.add_graph(v_iri) INTO v_g;
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, v_iri || '#');
  PERFORM pgrdf.materialize(v_g);
  RAISE NOTICE 'ckp.import_module: % imported into %', p_module, v_iri;
END;
$procedure$
;

CALL ckp._enforce_internal_floor();
