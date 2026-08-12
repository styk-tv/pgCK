-- pgck 0.4.48 — add_class projects the properties it was given
--
-- REPORTED by pgCK.MCP, re-measured here in source: ckp._op_to_ttl's add_class
-- arm read `class`/`targetClass`/`about` and NEVER read detail.properties. It
-- emitted exactly one quad --
--     <urn:ckp:pgck-mcp/type/ToolProjection> a owl:Class .
-- -- reported graph_changed:true, applied_quads:1, and dropped both declared
-- property shapes. Same family as detail/proposalDetail (0.4.46) and the inert
-- epoch: a payload key the door does not read, accepted with no complaint.
--
-- ONE CORRECTION to the report, and it makes this worse rather than better.
-- The claim was that the resulting type "cannot be sealed against" because seal
-- refuses a type nothing targets. It does not: ckp._type_admitted accepts
--     { ?s sh:targetClass <T> } UNION { <T> a rdfs:Class } UNION { <T> a owl:Class }
-- so `a owl:Class` ADMITS the type on its own. The type is therefore sealable
-- immediately and, with no shape targeting it, every instance validates
-- VACUOUSLY. add_class did not create an unusable type; it created a vacuity
-- generator, through the governed door, at a sealed epoch.
--
-- FIXED: properties[] are projected as a sh:NodeShape targeting the class, with
-- the same per-property gate add_property already applies (path IRI required,
-- minCount integer, datatype IRI). A malformed property is REFUSED at propose,
-- never dropped -- silently narrowing an enforcement surface is un-enforcement
-- nobody can see.
--
-- LEFT ALONE, deliberately: a bare add_class with no properties still emits the
-- class alone. Five smoke tests use it that way as a projectored op for the
-- governance loop, and it is a legitimate building block before an add_property.
-- But the vacuity window above is real for exactly as long as no shape targets
-- the new class. Closing it means either refusing bare add_class or making
-- _type_admitted require a targeting shape -- a doctrine decision, not a
-- projector fix, and not one to take unilaterally.

CREATE OR REPLACE FUNCTION ckp._op_to_ttl(p_prop jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C          text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_iri_re   text := '^[A-Za-z][A-Za-z0-9+.:#/_-]*$';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';            -- state names (no quote/space)
  v_op       text := p_prop->>(C||'proposalOp');
  v_detail   jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_class    text;
  v_path     text;
  v_min      int;
  v_dtype    text;
  v_dt_line  text := '';
  v_map      jsonb;
  v_fs       text;
  v_ts       text;
  v_ttl      text;
BEGIN
  IF v_op = 'add_property' THEN
    v_class := v_detail->>'targetClass';
    v_path  := v_detail->>'path';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: targetClass must be an IRI, got %', v_class; END IF;
    IF v_path IS NULL OR v_path !~ v_iri_re THEN
      RAISE EXCEPTION 'add_property: path must be an IRI, got %', v_path; END IF;
    BEGIN
      v_min := COALESCE((v_detail->>'minCount')::int, 1);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'add_property: minCount must be an integer, got %', v_detail->>'minCount'; END;
    v_dtype := v_detail->>'datatype';
    IF v_dtype IS NOT NULL THEN
      IF v_dtype !~ v_iri_re THEN RAISE EXCEPTION 'add_property: datatype must be an IRI, got %', v_dtype; END IF;
      v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
    END IF;
    RETURN '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '[ a sh:NodeShape ; sh:targetClass <'||v_class||'> ; '||
           'sh:property [ sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' ] ] .';

  ELSIF v_op = 'add_class' THEN
    v_class := COALESCE(v_detail->>'class', v_detail->>'targetClass', p_prop->>(C||'about'));
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'add_class: class must be an IRI, got %', v_class; END IF;
    -- detail.properties[] WAS ACCEPTED AND SILENTLY DROPPED. The op emitted one
    -- quad (<class> a owl:Class) and reported graph_changed:true, so a caller
    -- who declared constraints got a class carrying none and no complaint --
    -- the same family as detail/proposalDetail and the inert epoch. Reported by
    -- pgCK.MCP against urn:ckp:pgck-mcp/type/ToolProjection: two property
    -- shapes sent, one quad applied, nothing validatable.
    --
    -- Emit the NodeShape too, with the same per-property gate add_property uses.
    -- A malformed property is REFUSED here, never dropped: silently narrowing a
    -- shape is un-enforcement nobody sees.
    v_ts := '';
    IF jsonb_typeof(v_detail->'properties') = 'array' THEN
      FOR v_map IN SELECT jsonb_array_elements(v_detail->'properties') LOOP
        v_path := v_map->>'path';
        IF v_path IS NULL OR v_path !~ v_iri_re THEN
          RAISE EXCEPTION 'add_class: property path must be an IRI, got %', v_path; END IF;
        BEGIN
          v_min := COALESCE((v_map->>'minCount')::int, 1);
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'add_class: property minCount must be an integer, got %', v_map->>'minCount'; END;
        v_dtype := v_map->>'datatype';
        v_dt_line := '';
        IF v_dtype IS NOT NULL THEN
          IF v_dtype !~ v_iri_re THEN
            RAISE EXCEPTION 'add_class: property datatype must be an IRI, got %', v_dtype; END IF;
          v_dt_line := ' ; sh:datatype <'||v_dtype||'>';
        END IF;
        v_ts := v_ts||' ; sh:property [ sh:path <'||v_path||'> ; sh:minCount '||v_min::text||v_dt_line||' ]';
      END LOOP;
    END IF;
    IF v_ts = '' THEN
      -- bare declaration: a building block for a following add_property. NOTE it
      -- is admitted the moment it lands (_type_admitted accepts `a owl:Class`),
      -- so until a shape targets it an instance of this type validates
      -- VACUOUSLY. That window is a doctrine question, not a projector bug.
      RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
             '<'||v_class||'> a owl:Class .';
    END IF;
    RETURN '@prefix owl: <http://www.w3.org/2002/07/owl#> .'||chr(10)||
           '@prefix sh: <http://www.w3.org/ns/shacl#> .'||chr(10)||
           '<'||v_class||'> a owl:Class .'||chr(10)||
           '[ a sh:NodeShape ; sh:targetClass <'||v_class||'>'||v_ts||' ] .';

  ELSIF v_op = 'set_transition_map' THEN
    v_class := v_detail->>'targetClass';
    v_map   := v_detail->'map';
    IF v_class IS NULL OR v_class !~ v_iri_re THEN
      RAISE EXCEPTION 'set_transition_map: targetClass must be an IRI, got %', v_class; END IF;
    IF v_map IS NULL OR jsonb_typeof(v_map) <> 'object' THEN
      RAISE EXCEPTION 'set_transition_map: map must be an object {from:[to,…]}'; END IF;
    v_ttl := '@prefix ckp: <'||C||'> .'||chr(10);
    FOR v_fs IN SELECT jsonb_object_keys(v_map) LOOP
      IF v_fs !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad from-state %', v_fs; END IF;
      IF jsonb_typeof(v_map->v_fs) <> 'array' THEN
        RAISE EXCEPTION 'set_transition_map: map[%] must be an array of to-states', v_fs; END IF;
      FOR v_ts IN SELECT jsonb_array_elements_text(v_map->v_fs) LOOP
        IF v_ts !~ v_state_re THEN RAISE EXCEPTION 'set_transition_map: bad to-state %', v_ts; END IF;
        v_ttl := v_ttl || '<'||v_class||'> ckp:allowsTransition '||
                 '[ ckp:fromState "'||v_fs||'" ; ckp:toState "'||v_ts||'" ] .'||chr(10);
      END LOOP;
    END LOOP;
    RETURN v_ttl;

  END IF;
  -- Ops without a shape projection yet (modify_shape_constraint, set_quorum,
  -- set_materialize_policy) leave the graph unchanged here; add_affordance with a query
  -- is handled by ckp.apply's register step. Translators land as each is built.
  RETURN NULL;
END;
$function$;
