-- pgck--0.4.87--0.4.88.sql — G-1: germination stamps its own transport segment.
--
-- THE DEFECT, and it was ours. Root 97f97cb2… (2026-08-28) added ckp:transportSegment
-- to ckp:KernelShape with minCount 1. The constraint is correct and stays. What did not
-- move with it was the EMITTER: ckp.germinate_kernel sealed a ckp:Kernel carrying label,
-- epoch, inProject and hasOrgan — and no transportSegment. So the kernel reached its own
-- composed-surface gate with value null and was refused:
--
--   {"value": null, "focusNode": "urn:ckp:<p>/kernel",
--    "resultPath": "…core#transportSegment",
--    "sourceConstraintComponent": "…shacl#MinCountConstraintComponent"}
--
-- Germination was therefore IMPOSSIBLE on every door carrying that root — pgck.localhost
-- and ckdev.localhost — while ckone (root 7de02b35…, no such property) was unaffected.
-- A germinate that "works on ckone and fails on ckdev" is this, not a bench mystery.
--
-- Reported by CK.Lib.Js (SPEC.CK-LIB-JS.v1.6.1-to-PGCK-4) after they attempted the act
-- correctly end to end — per-door credential, W0-verified connection, canonical id,
-- projectKind supplied. Reproduced here independently before this fix was written.
--
-- WHY THE ORIGINAL VERIFICATION MISSED IT. The negative control shipped with the root
-- sealed a ckp:Kernel DIRECTLY with a SUPPLIED segment, so it fired sh:pattern and passed
-- for the right reason. The germinate path fires MinCount — an ABSENT segment. The
-- constraint was proven; the path that must satisfy it was never exercised. This is the
-- standing rule restated: emission and shape move in ONE act, or the gate becomes a total
-- write outage on its own front door.
--
-- THE FIX. Derive the segment inside the substrate from the project id the caller already
-- named and this function has ALREADY validated against ^[a-z0-9]+(-[a-z0-9]+)*$ at the
-- canonical guard above the seal. The caller says WHAT; the substrate derives the wire
-- form. A caller-supplied transportSegment remains ignored on purpose — it would be one
-- more place two names could disagree.
--
-- THE GATE IS NOT LOOSENED. ckp:KernelShape is untouched: a direct seal of a ckp:Kernel
-- without the property still refuses MinCount. Only the emitter changed.
--
-- MIGRATION NOTE. ckp:Kernel instances sealed BEFORE this release carry no
-- transportSegment and will refuse on re-validation. Virgin benches have none. A bench
-- holding a germinated kernel either re-germinates it or accepts that it re-validates RED
-- until it does; nothing here backfills silently, because a backfilled segment would be a
-- fact nobody sealed.

CREATE OR REPLACE FUNCTION ckp.germinate_kernel(p_project text, p_label text DEFAULT NULL,
                                                -- 0.4.81: DEFAULT NULL, not
                                                -- 'personal'. NULL is the ABSENCE
                                                -- itself; ProjectShape then refuses
                                                -- on minCount/sh:in and names the
                                                -- clause, instead of the substrate
                                                -- choosing a kind nobody asked for.
                                                p_kind text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub   text := NULLIF(current_setting('ckp.requester', true), '');
  v_owner text;
  v_label text := COALESCE(p_label, p_project);
  v_iri   text := format('urn:ckp:%s/kernel/ck', p_project);
  v_g     int;
  v_ttl   text;
  v_base  text := format('urn:ckp:%s', p_project);
  v_kid   text := format('urn:ckp:%s/kernel', p_project);
  v_pid   text := format('urn:ckp:project:%s', p_project);
BEGIN
  IF p_project IS NULL OR btrim(p_project) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'project required');
  END IF;
  -- The transport segment is one NATS token. A dotted name can never be granted
  -- (configured_kernels drops it), so germinating one would build a kernel nobody
  -- can ever reach. Refuse at the door with the slug it should use.
  -- p_project is ONE transport segment, not an IRI. The metacharacter test alone
  -- let ':' and '/' through, so a caller passing the project URN
  -- ('urn:ckp:project:ck-lib-js') germinated a graph named
  -- <urn:ckp:urn:ckp:project:ck-lib-js/kernel/ck> -- structurally valid, and
  -- reachable by nobody. Measured on the bench: 22 asserted triples in exactly
  -- that graph. Require a bare segment; the metacharacter case keeps its own
  -- message because the slug is actionable there.
  IF p_project ~ '[.*> \t\r\n]' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', format('kernel id %L carries a NATS subject metacharacter, so it can never be granted. Use %L.',
                      p_project, ckp._slug(p_project)));
  END IF;
  IF p_project !~ '^[a-z0-9]+(-[a-z0-9]+)*$' THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', format('kernel id %L is not canonical. A project name is lowercase, dashes optional, one transport segment -- use %L.',
                      p_project, ckp._slug(regexp_replace(p_project, '^.*[:/]', ''))));
  END IF;
  -- IDENTITY IS SERVER-DERIVED. No verified connection, no owner, no germination —
  -- fail closed rather than mint an unowned project or invent an owner.
  IF v_sub IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'refused', true,
      'error', 'germination requires a verified identity: ckp.ownedBy is stamped from the connection, never supplied. Anonymous callers cannot own a project.');
  END IF;
  v_owner := 'urn:ckp:participant:' || ckp._slug(v_sub);

  -- 1. the structure — Kernel + three organs, counted dependencies, gated authorities
  v_g := pgrdf.add_graph(v_iri);
  PERFORM pgrdf.clear_graph(v_g);
  v_ttl := format($ttl$
@prefix ckp:  <https://conceptkernel.org/ontology/v3.11/core#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
<%1$s/kernel> a ckp:Kernel ; rdfs:label %2$L ; ckp:epoch 0 ;
  ckp:inProject <%3$s> ;
  ckp:hasOrgan <%1$s/organ/ck> , <%1$s/organ/tool> , <%1$s/organ/data> .
<%1$s/organ/ck>   a ckp:Organ , ckp:CK   ; ckp:organKind "ck"   ; ckp:writeAuthority "governed-only" .
<%1$s/organ/tool> a ckp:Organ , ckp:TOOL ; ckp:organKind "tool" ; ckp:writeAuthority "readonly-on-ontology" ;
  ckp:dependsOn <%1$s/organ/ck> .
<%1$s/organ/data> a ckp:Organ , ckp:DATA ; ckp:organKind "data" ; ckp:writeAuthority "readwrite" ;
  ckp:dependsOn <%1$s/organ/ck> , <%1$s/organ/tool> .
$ttl$, v_base, v_label, v_pid);
  PERFORM pgrdf.parse_turtle(v_ttl, v_g, v_iri || '#');
  PERFORM pgrdf.materialize(v_g);
  GRANT ALL ON ALL TABLES    IN SCHEMA pgrdf TO ck_substrate;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA pgrdf TO ck_substrate;

  -- 2. the Project — ownedBy STAMPED, never supplied. This is the triple a client
  --    cannot write and the reason germination is a governed verb at all.
  PERFORM ckp.seal(v_pid, jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Project',
    '@id',  v_pid,
    'http://www.w3.org/2000/01/rdf-schema#label', v_label,
    'https://conceptkernel.org/ontology/v3.11/core#projectKind', p_kind,
    'https://conceptkernel.org/ontology/v3.11/core#ownedBy', v_owner));

  -- 3. the Kernel as a SEALED, ATTRIBUTED fact — so the kernel exists in the ledger
  --    and not only as quads a stranger could have written.
  PERFORM ckp.seal(v_kid, jsonb_build_object(
    'type', 'https://conceptkernel.org/ontology/v3.11/core#Kernel',
    '@id',  v_kid,
    'http://www.w3.org/2000/01/rdf-schema#label', v_label,
    'https://conceptkernel.org/ontology/v3.11/core#epoch', 0,
    'https://conceptkernel.org/ontology/v3.11/core#inProject', v_pid,
    -- 0.4.88 (G-1): the wire form is the SUBSTRATE's, derived from the id the caller
    -- already named and this function already validated at the canonical guard above.
    -- KernelShape gained transportSegment with minCount 1 in root 97f97cb2…; this
    -- emitter did not move with it, so germination refused itself on every door
    -- carrying that root — MinCountConstraintComponent, value null, fleet-wide.
    -- Not caller-supplied ON PURPOSE: a payload-supplied segment is one more place
    -- two names could disagree, and the caller has already said which project it means.
    'https://conceptkernel.org/ontology/v3.11/core#transportSegment', p_project,
    'https://conceptkernel.org/ontology/v3.11/core#hasOrgan',
      -- The organs live at <base>/organ/*, NOT <base>/kernel/organ/*. Both the
      -- graph above and pgCK's own kernel use the former; deriving these from
      -- v_kid (which already ends in /kernel) sealed a Kernel whose hasOrgan
      -- pointed at three resources that do not exist. KernelShape only counts
      -- them and checks nodeKind, so the gate passed and the drift was silent.
      jsonb_build_array(v_base||'/organ/ck', v_base||'/organ/tool', v_base||'/organ/data')));

  RETURN jsonb_build_object('ok', true, 'kernel', v_kid, 'graph', v_iri,
                            'project', v_pid, 'ownedBy', v_owner, 'organs', 3);
END;
$function$;

COMMENT ON FUNCTION ckp.germinate_kernel(text, text, text) IS
  'Governed germination. A client declares its STRUCTURE (Kernel + three organs); the '
  'substrate stamps WHO OWNS IT (ckp:ownedBy) from the verified connection, exactly as '
  'ckp:createdBy is derived — never from the payload. Refuses anonymously, and refuses a '
  'kernel id carrying a NATS subject metacharacter because such a kernel could never be '
  'granted. Replaces the pgRDF route, which lands correct structure that belongs to nobody.';
