-- pgck 0.4.41 -> 0.4.42
--
-- #46/#47 IN ONE ACT: the board leaves the v3.7 namespace AND gains its shapes.
-- Moving one without the other is what failed twice:
--   1fb173e  the SHAPE was re-pointed and the emission stayed — "a v3.8 shape
--            targets nothing the re-pointed substrate emits, the PASS-10 vacuous
--            direction"
--   2026-08-11  the DECLARATION was removed and the emission stayed (mine)
-- Both produce a vacuous surface. Emission and shape move together — the PASS-18
-- lesson this repo has recorded twice and violated twice.
--
-- WHY urn:ckp:board/ AND NOT wave: — wave:TicketShape requires openedAtPass and
-- benchClass, pass-process metadata a consumer board task has no basis for.
-- Inventing values to satisfy a shape is the "invented contract" this epoch exists
-- to end. The board is DOMAIN vocabulary per SPEC.CKP.v3.11 §2.
--
-- WHY FLAT rather than s48's type/prop split — ckp.dispatch carries ONE namespace
-- constant N for both types (N||'Task') and properties (N||'title'), so a flat
-- namespace repoints reads and writes coherently in a single change. A split would
-- need the emitter restructured, and that is where drift enters.
--
-- The shapes live in examples/example.kernel.ttl, loaded by ckp.load_kernel into
-- urn:ckp:<project>/kernel/ck, which _composed_shapes already unions into the
-- enforcement surface. The namespace is project-independent so shape and emission
-- cannot drift apart per project.



-- ckp._type_admitted — namespace constant repointed to urn:ckp:board/
CREATE OR REPLACE FUNCTION ckp._type_admitted(p_type text, p_project text, p_comp integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_comp_iri text; v_board_iri text; v_ask text;
BEGIN
  IF p_type IS NULL OR position(':' in p_type) = 0 THEN
    RETURN false;   -- no resolvable type is not an admitted type
  END IF;
  -- 0.4.42: the #46 TRANSITIONAL ALLOWANCE IS DELETED, and its own exit condition
  -- is now met. It read "tolerate it until #46 re-points the body construction, at
  -- which point the board path becomes non-vacuously validated". Both halves landed
  -- in one act: ckp.dispatch's namespace constant N moved off …/ontology/v3.7/ to
  -- urn:ckp:board/, and urn:ckp:board/{Task,Goal,Edge,Message} now carry shapes in
  -- the project kernel graph. While it stood, R2 was open on the write path — seal
  -- consults this function, so a v3.7 type reached the SHACL gate, was targeted by
  -- no shape, took a VACUOUS conforms:true and sealed. An undeclared type is now
  -- refused whatever namespace it carries.
  -- Admitted = the type is DECLARED (a shape targets it, or it is a declared
  -- class) anywhere the kernel loaded: the composed core+ck surface OR the
  -- project board. Reads the same surfaces the gate/self-test consult — never
  -- a second authority. An invented URN in none of them is refused.
  v_comp_iri  := pgrdf.graph_iri(p_comp);
  v_board_iri := format('urn:ckp:%s/kernel/board', p_project);
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask
  FROM pgrdf.sparql(format($q$
    PREFIX sh:   <http://www.w3.org/ns/shacl#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX owl:  <http://www.w3.org/2002/07/owl#>
    ASK WHERE { GRAPH ?g {
      { ?s sh:targetClass <%s> } UNION { <%s> a rdfs:Class } UNION { <%s> a owl:Class }
    } FILTER(?g IN (<%s>, <%s>)) }
  $q$, p_type, p_type, p_type, v_comp_iri, v_board_iri)) j
  LIMIT 1;
  RETURN COALESCE(v_ask, 'false') = 'true';
END;
$function$;


-- ckp._query — namespace constant repointed to urn:ckp:board/
CREATE OR REPLACE FUNCTION ckp._query(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  p_type text := p_payload->>'type';
  p_kern text := p_payload->>'kernel';
  p_n    int  := COALESCE((p_payload->>'n')::int, (p_payload->>'limit')::int,
                          CASE WHEN p_verb='instances.last' THEN 10 ELSE 50 END);
BEGIN
  IF p_verb = 'instance.get' THEN
    RETURN jsonb_build_object('ok', true, 'instance', ckp._envelope(p_payload->>'id'));
  ELSIF p_verb = 'instances.count' THEN
    RETURN jsonb_build_object('ok', true, 'count', (
      SELECT count(*) FROM ckp.instances
      WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
        AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern)));
  ELSE  -- instances.list / instances.last
    RETURN jsonb_build_object('ok', true, 'count', (
        SELECT count(*) FROM ckp.instances
        WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
          AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern)),
      'instances', COALESCE((
        SELECT jsonb_agg(ckp._envelope(id) ORDER BY ts DESC)
        FROM (SELECT id, ts_created ts FROM ckp.instances
          WHERE (p_type IS NULL OR body->>'type'=p_type OR body->>'type' LIKE '%'||p_type)
            AND (p_kern IS NULL OR body->>(N||'target_kernel')=p_kern)
          ORDER BY ts_created DESC LIMIT p_n) s), '[]'::jsonb));
  END IF;
END;
$function$;


-- ckp.create_typed — namespace constant repointed to urn:ckp:board/
CREATE OR REPLACE FUNCTION ckp.create_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_type    text := p_payload->>'type';
  v_proj    text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  -- F-A / P0-C (pgCK#26): identity is SERVER-DERIVED from the verified
  -- connection (the ckp.requester GUC the trusted ingress sets from the
  -- NATS-verified bearer), NEVER the client payload. A payload {sub} is
  -- ignored — it cannot forge created_by or the participant claim. This is
  -- the same rule task.create and notify already carry; the generic path
  -- was the last reader of payload sub (measured: s58's instance.create
  -- case sealed participant:attacker before this fix).
  v_sub     text := current_setting('ckp.requester', true);
  N         text := 'urn:ckp:board/';       -- v3.7 core NS (gate + task.create)
  v_core    text[] := ARRAY['lifecycle_state'];                       -- recognized core keys → core NS
  v_local   text;
  v_ns      text;
  v_iid     text;
  v_propmap jsonb;
  v_body    jsonb;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;
  IF position(':' in v_type) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_must_be_iri',
      'hint', 'instance.create {type} must be the full class IRI the kernel declares (sh:targetClass), e.g. urn:ckp:<project>/type/Ship');
  END IF;

  v_local := regexp_replace(v_type, '^.*[/#]', '');
  v_ns    := regexp_replace(v_type, '[^/#]*$', '');
  v_iid   := lower(v_local) || '-' || (extract(epoch from clock_timestamp())*1e9)::bigint::text;

  SELECT COALESCE(jsonb_object_agg(regexp_replace(path, '^.*[/#]', ''), path), '{}'::jsonb)
    INTO v_propmap
  FROM (
    SELECT DISTINCT j->>'path' AS path
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?path WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
        ?s sh:targetClass <%s> ; sh:property ?p . ?p sh:path ?path } }
    $q$, v_proj, v_type)) AS j
    WHERE j->>'path' IS NOT NULL
  ) p;

  v_body := jsonb_build_object('type', v_type, '@id', 'ckp://' || v_local || '#' || v_iid);
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_payload)
  LOOP
    CONTINUE WHEN v_key IN ('type', 'sub', '@id', 'participant');     -- control keys, not data (sub/participant: identity is never payload)
    IF position(':' in v_key) > 0 THEN
      v_keyiri := v_key;                                             -- already a full IRI: pass through
    ELSIF v_propmap ? v_key THEN
      v_keyiri := v_propmap->>v_key;                                 -- declared localname -> its path IRI
    ELSIF v_key = ANY(v_core) THEN
      v_keyiri := N || v_key;                                        -- v3.7 core key -> core NS (gate + task.create)
    ELSE
      v_keyiri := v_ns || v_key;                                     -- other undeclared -> under the type's NS
    END IF;
    v_body := v_body || jsonb_build_object(v_keyiri, v_val);         -- `->` value: preserves number/bool/object types
  END LOOP;

  v_body := v_body || jsonb_build_object(
    'urn:ckp:board/created_at',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  IF v_sub IS NOT NULL THEN
    -- created_by from the VERIFIED requester (same shape as task.create), and
    -- the participant claim seal maps to core#participant — also verified.
    v_body := v_body || jsonb_build_object(
      N||'created_by', 'urn:ckp:participant:'||ckp._slug(v_sub),
      'participant', jsonb_build_object('sub', v_sub));
  END IF;

  PERFORM ckp.seal(v_iid, v_body);

  RETURN jsonb_build_object('ok', true, 'id', v_iid, 'type', v_type,
    'verified', ckp.verify(v_iid),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_iid ORDER BY id DESC LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;


-- ckp.dispatch — namespace constant repointed to urn:ckp:board/
CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_kernel_urn text, p_payload jsonb, p_identity text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  res jsonb;
BEGIN
  -- Transitional minimal surface (CI-A-2). The full §2.2 fail-fast order lands in
  -- CI-B/CI-C/CI-D; here we prove the locked door is usable as definer.
  CASE p_verb
    WHEN 'instances.count' THEN
      res := jsonb_build_object('ok', true, 'count', (SELECT count(*) FROM ckp.instances));
    WHEN 'instance.verify' THEN
      res := jsonb_build_object('ok', true, 'id', p_payload->>'id',
                                'verified', ckp.verify(p_payload->>'id'));
    ELSE
      -- unknown verb -> the delegation seam (becomes a sealed-delegation fact in CI-B-4).
      res := jsonb_build_object('ok', false, 'delegate', true,
                                'error', 'verb not governed yet (CI-B): ' || p_verb);
  END CASE;
  RETURN res || jsonb_build_object('kernel', p_kernel_urn);
END;
$function$;


-- ckp.project_instance_label — namespace constant repointed to urn:ckp:board/
CREATE OR REPLACE FUNCTION ckp.project_instance_label()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  v_type text := NEW.body->>'type';
  v_id   text := COALESCE(NEW.body->>'@id', 'urn:ckp:instance:'||NEW.id);
  v_lbl  text;
  v_proj text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_g    bigint;
BEGIN
  v_lbl := COALESCE(NEW.body->>RL, NEW.body->>'rdfs:label',
                    NEW.body->>(N||'title'), NEW.body->>'title',
                    NEW.body->>(N||'name'), NEW.body->>'name');
  -- only label-bearing, well-formed instances are projected (Proposals/Votes/Edges have no label).
  IF v_lbl IS NULL OR v_type IS NULL OR v_id !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN NEW;
  END IF;
  BEGIN
    -- DETERMINISTIC HIGH graph id per project (NOT the IRI-variant auto-id, which assigns the lowest
    -- free id and would steal the reserved core(1)/kernel(2) ids if a write lands before ckp.boot — the
    -- s34 fresh-cluster failure). 1.3e9 + hash keeps it clear of every auto-assigned scratch/board id.
    v_g := 1300000000 + (abs(hashtext(format('urn:ckp:%s/instances', v_proj))) % 90000000);
    PERFORM pgrdf.add_graph(v_g, format('urn:ckp:%s/instances', v_proj));
    PERFORM pgrdf.parse_turtle(
      format('<%s> a <%s> ; <%s> "%s" .', v_id, v_type, RL,
             replace(replace(v_lbl, '\', '\\'), '"', '\"')),
      v_g, format('urn:ckp:%s/instances#', v_proj));
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- projection is a search index, never a write-path gate: a failure must not fail the seal.
  END;
  RETURN NEW;
END;
$function$;


-- ckp.transition — namespace constant repointed to urn:ckp:board/
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
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to,
                            'source', v_src, 'verified', ckp.verify(v_id));
END;
$function$;
