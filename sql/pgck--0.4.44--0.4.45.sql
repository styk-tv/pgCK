-- pgck 0.4.45 — the substrate stops shipping a non-canonical name for itself
--
-- THE RULE. A project name is ONE transport segment, lowercase, dashes
-- optional. `pgCK` is the repo and the display name; it was never a valid
-- project name.
--
-- WHAT SHIPPED. pgck-baseline.sql hard-coded 'pgCK' in 37 places: all 26
-- affordance_registry seed rows, their input.kernel.pgCK.action.* subjects, the
-- event.kernel.pgCK.*.sealed subject, and the kernel_epoch lookups inside
-- ckp.apply / bump_epoch / compile_plans / concept_match. So the SUBSTRATE
-- published its verbs under a name no conforming client can produce.
--
-- HOW IT PRESENTED. A client that correctly slugs its workspace publishes to
-- input.kernel.pgck.action.*; the relay sets ckp.project = 'pgck'; every
-- registry row says 'pgCK'; affordances returns EMPTY. That was read (by me,
-- repeatedly, and wrongly) as a client regression. It is the seed.
--
-- WORSE: dispatch then authorized from the registry anyway, so an empty
-- affordance list did not mean an empty surface -- fail-open, closed in 0.4.44.
--
-- ALSO HERE. germinate now requires the canonical form, refusing an IRI or a
-- capitalised name and naming the segment to use. The bench carries
--   <urn:ckp:urn:ckp:project:ck-lib-js/kernel/ck>   22 asserted triples
-- from a caller that passed a full URN where the segment belongs: the old
-- guard tested only for NATS metacharacters and let ':' and '/' through.
--
-- MIGRATION. Registry rows and kernel_epoch are hand-registered routing state,
-- not sealed facts, so they are repointed in place. Sealed ckp:Affordance
-- instances carry producedBy urn:ckp:pgCK/kernel/ck and are NOT rewritten --
-- a seal is exactly what cannot be edited. They are superseded when the
-- canonical kernel materializes its epoch, and the pgCK-named graphs are gone.

CREATE OR REPLACE FUNCTION ckp.apply(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C           text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_about     text := p_payload->>'about';
  v_proj      text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_prop      jsonb;
  v_pid       text;
  v_op        text;
  v_quorum    int;
  v_approvals int;
  v_epoch     int;
  v_new_body  jsonb;
  v_ttl       text;
  v_ga        jsonb;
  v_applied   jsonb := jsonb_build_object('graph_changed', false);
BEGIN
  IF v_about IS NULL OR v_about !~ '^[A-Za-z][A-Za-z0-9+.:#/_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_about', 'about', v_about);
  END IF;
  SELECT id, body INTO v_pid, v_prop FROM ckp.instances
    WHERE body->>'@id' = v_about AND body->>'type' = C||'Proposal';
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_proposal', 'about', v_about);
  END IF;
  IF v_prop->>(C||'proposalState') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'proposal_not_pending', 'state', v_prop->>(C||'proposalState'));
  END IF;
  v_quorum := COALESCE((v_prop->>(C||'requiresQuorum'))::int, 1);
  SELECT count(*) INTO v_approvals FROM ckp.instances
    WHERE body->>'type' = C||'Vote' AND body->>(C||'about') = v_about AND body->>(C||'voteValue') = 'approve';
  IF v_approvals < v_quorum THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quorum_not_met', 'approvals', v_approvals, 'quorum', v_quorum);
  END IF;

  v_op := v_prop->>(C||'proposalOp');

  -- 4a. GRAPH APPLY (shape ops) — translate the op into the kernel graph (the §5.2 EFFECT).
  BEGIN
    v_ttl := ckp._op_to_ttl(v_prop);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'op_translate_failed', 'detail', SQLERRM);
  END;
  IF v_ttl IS NOT NULL THEN
    v_ga := ckp.apply_shape_ttl(v_ttl, v_proj);
    IF (v_ga->>'ok') IS DISTINCT FROM 'true' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'graph_apply_failed', 'detail', v_ga);
    END IF;
    v_applied := jsonb_build_object('graph_changed', true, 'applied_quads', v_ga->'applied_quads');
  END IF;

  -- 4b. CASCADE — epoch advance, and it MUST produce a sealed Materialization
  --     (P0-E, pgCK#28). The epoch is not a counter: the bump recompiles the
  --     plan surface (compile_plans + plan_cache_clear inside bump_epoch), and
  --     the rebuild is SEALED as a first-class ckp:Materialization that
  --     produces a ckp:Epoch carrying the surface digest. All in THIS txn: if
  --     the Materialization or Epoch fails its shape gate, the whole apply
  --     rolls back — a bumped epoch with no valid Materialization cannot
  --     commit. "Show me the Materialization that produced this epoch, and
  --     re-derive the surface at that epoch" is answerable from the seals.
  DECLARE
    v_from   int := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = 'pgck'), 1);
    v_comp_e int;
    v_srcd   text;
    v_surfd  text;
    v_kiri   text := format('urn:ckp:%s/kernel/ck', v_proj);
    v_eiri   text;
    v_miri   text;
  BEGIN
    v_epoch := ckp.bump_epoch('pgck');           -- recompiles plans + clears cache (same txn)
    v_comp_e := ckp._composed_shapes(v_proj);    -- rebuild the enforcement surface from the new shapes
    v_srcd  := ckp._surface_digest(pgrdf.add_graph(v_kiri));   -- the governed source shapes
    v_surfd := ckp._surface_digest(v_comp_e);                  -- the enforcement surface produced
    v_eiri  := format('urn:ckp:%s/epoch/%s', v_proj, v_epoch);
    v_miri  := format('urn:ckp:%s/materialization/%s', v_proj, v_epoch);
    -- the Epoch resource: the position, named by the digest of its surface.
    PERFORM ckp.seal('epoch-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Epoch', '@id', v_eiri,
      C||'epoch', to_jsonb(v_epoch),
      C||'surfaceDigest', v_surfd));
    -- the Materialization: the sealed rebuild that produced that epoch.
    PERFORM ckp.seal('mat-'||v_proj||'-'||v_epoch, jsonb_build_object(
      'type', C||'Materialization', '@id', v_miri,
      C||'materializes', v_kiri,
      C||'fromEpoch', to_jsonb(v_from),
      C||'toEpoch', to_jsonb(v_epoch),
      C||'sourceDigest', v_srcd,
      C||'surfaceDigest', v_surfd,
      C||'producesEpoch', v_eiri));
  END;

  -- 4c. QUERY AFFORDANCE (Tier 2 3/3b) — an add_affordance carrying query text is compiled into
  --     ckp.plans + registered plane='query', keyed to the new epoch (governed, sealed).
  IF v_op = 'add_affordance' AND (v_prop->'proposalDetail' ? 'query') THEN
    BEGIN
      PERFORM ckp.register_query_affordance(v_prop, v_proj, v_epoch);
      v_applied := v_applied || jsonb_build_object('query_affordance', v_prop->'proposalDetail'->>'verb');
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', 'affordance_register_failed', 'detail', SQLERRM);
    END;
  END IF;

  v_new_body := v_prop || jsonb_build_object(C||'proposalState', 'applied', C||'appliedEpoch', v_epoch::text);
  PERFORM ckp.seal(v_pid, v_new_body);

  RETURN jsonb_build_object('ok', true, 'proposal', v_about, 'state', 'applied', 'epoch', v_epoch,
                            'op', v_op, 'approvals', v_approvals, 'applied', v_applied,
                            'verified', ckp.verify(v_pid));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.bump_epoch(p_kernel text DEFAULT 'pgck'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE v_epoch integer;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  UPDATE ckp.kernel_epoch SET epoch = epoch + 1 WHERE kernel = p_kernel RETURNING epoch INTO v_epoch;
  PERFORM ckp.compile_plans(p_kernel);   -- recompile at the new epoch (same txn)
  PERFORM pgrdf.plan_cache_clear();       -- invalidate the engine SPARQL plan cache (same txn)
  RETURN v_epoch;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.compile_plans(p_kernel text DEFAULT 'pgck'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_epoch integer;
  v_n     integer := 0;
  r       record;
BEGIN
  INSERT INTO ckp.kernel_epoch(kernel, epoch) VALUES (p_kernel, 1) ON CONFLICT (kernel) DO NOTHING;
  SELECT epoch INTO v_epoch FROM ckp.kernel_epoch WHERE kernel = p_kernel;

  FOR r IN
    SELECT * FROM (VALUES
      ('instance.get',
        '{"kind":"sql","statement":"SELECT body FROM ckp.instances WHERE id = $1","params":["id"]}'::jsonb),
      ('instance.count',
        '{"kind":"sql","statement":"SELECT count(*) AS n FROM ckp.instances","params":[]}'::jsonb)
    ) AS cat(verb, plan)
  LOOP
    INSERT INTO ckp.plans(kernel, verb, epoch, plan)
      VALUES (p_kernel, r.verb, v_epoch, r.plan)
      ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.concept_match(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_term   text := p_payload->>'term';
  v_proj   text := COALESCE(NULLIF(current_setting('ckp.project', true), ''), 'demo');
  v_limit  int  := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 10), 1), 100);
  v_term_esc text;
  v_plan   jsonb;
  v_stmt   text;
  v_rows   jsonb;
BEGIN
  IF v_term IS NULL OR length(v_term) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'term', v_term);
  END IF;

  -- the GOVERNED query: latest-epoch concept.match plan.
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel = 'pgck' AND verb = 'concept.match' ORDER BY epoch DESC LIMIT 1;

  IF v_plan IS NOT NULL AND v_plan->>'kind' = 'sparql' THEN
    -- BIND (not reject): escape the term for the SPARQL string literal so any term is contained —
    -- an injection-shaped term becomes a literal that matches nothing (never breaks the query).
    v_term_esc := replace(replace(replace(v_term, '\', '\\'), '"', '\"'), chr(10), '\n');
    v_stmt := replace(v_plan->>'statement', '$graph$', format('urn:ckp:%s/instances', v_proj));
    v_stmt := replace(v_stmt, '$term$', v_term_esc);
    -- run + RANK in pgCK (exact > prefix > contains; the governed query supplies the matches).
    SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
      INTO v_rows
    FROM (
      SELECT j->>'id' AS id, j->>'label' AS lbl,
        CASE WHEN lower(j->>'label') = lower(v_term)         THEN 1
             WHEN lower(j->>'label') LIKE lower(v_term)||'%' THEN 2
             ELSE 3 END AS rnk
      FROM pgrdf.sparql(v_stmt) j
      LIMIT v_limit
    ) t;
    RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', true,
                              'count', COALESCE(jsonb_array_length(v_rows), 0),
                              'candidates', COALESCE(v_rows, '[]'::jsonb));
  END IF;

  -- fallback: the legacy in-table label search (no governed plan present).
  SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
  INTO v_rows FROM (
    SELECT id, lbl,
      CASE WHEN lower(lbl) = lower(v_term)         THEN 1
           WHEN lower(lbl) LIKE lower(v_term)||'%' THEN 2
           ELSE 3 END AS rnk
    FROM (
      SELECT id, COALESCE(body->>'rdfs:label',
                          body->>'urn:ckp:board/title',
                          body->>'title') AS lbl
      FROM ckp.instances
    ) s
    WHERE lbl ILIKE '%'||v_term||'%'
    ORDER BY rnk
    LIMIT v_limit
  ) t;
  RETURN jsonb_build_object('ok', true, 'term', v_term, 'governed', false,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'candidates', COALESCE(v_rows, '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp._dispatch_safe(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  v_out := ckp.dispatch(p_verb, p_payload);
  RETURN v_out;
EXCEPTION
  WHEN OTHERS THEN
    -- The refusal is the RESULT. Carry the clause the gate named, plus SQLSTATE
    -- so a caller can tell a shape refusal from a transport fault, and keep the
    -- verb so a Trace-Id correlation still resolves. Never re-raise: re-raising
    -- is what killed the worker.
    RETURN jsonb_build_object(
      'ok',      false,
      'refused', true,
      'verb',    p_verb,
      'sqlstate', SQLSTATE,
      'error',   SQLERRM
    );
END;
$function$;

COMMENT ON FUNCTION ckp._dispatch_safe(text, jsonb) IS
  'Transport-safe wrapper over ckp.dispatch. A gate refusal is returned as data '
  '({ok:false, refused:true, sqlstate, error}) instead of raising, because an '
  'unhandled RAISE inside the bgworker SPI call unwinds as a pgrx panic and '
  'terminates the worker — taking the auth-callout responder with it and closing '
  'the door for every client (measured 2026-08-11, pgck-bridge exit code 1).';

CREATE OR REPLACE FUNCTION ckp.germinate_kernel(p_project text, p_label text DEFAULT NULL,
                                                p_kind text DEFAULT 'personal')
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

CREATE OR REPLACE FUNCTION ckp.dispatch(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  N      text := 'urn:ckp:board/';
  RL     text := 'http://www.w3.org/2000/01/rdf-schema#label';
  req    jsonb := p_payload->'req';
  res    jsonb;
  v_proj text := COALESCE(current_setting('ckp.project', true), 'demo');
  v_idk  text := COALESCE(current_setting('ckp.identity_key', true), 'pgck-localhost');
  v_canon  text;   -- CI-B-2: canonical instance.* name (registry lookup key)
  v_aff    jsonb;  -- CI-B-1: the sealed affordance row (the registry IS the routing authority)
  v_legacy text;   -- CI-B-2: the legacy handler name (alias window)
BEGIN
  PERFORM set_config('ckp.project', v_proj, false);
  PERFORM set_config('ckp.identity_key', v_idk, false);

  -- CI-B-1/B-2 — the sealed registry is the SOLE routing authority. Resolve the canonical
  -- name + its sealed affordance row; an unregistered verb fails typed (unknown_affordance)
  -- with zero payload evaluation (no fallthrough); a delegate=true row is the Tier-2 tool
  -- seam; governance-plane verbs never execute here (proposal/vote/apply — CI-D). Otherwise
  -- resolve the legacy handler name (alias window) so the CASE below is unchanged and v0.3.0
  -- web2 keeps working.
  v_canon := ckp.verb_canon(p_verb);
  v_aff   := ckp.registry_lookup('pgck', v_canon);
  IF v_aff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_affordance', 'verb', p_verb)
      || jsonb_build_object('req', req);
  ELSIF COALESCE((v_aff->>'delegate')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'delegate', true, 'verb', p_verb,
      'error', 'verb delegated to tool tier: '||p_verb) || jsonb_build_object('req', req);
  ELSIF v_aff->>'plane' = 'governance' THEN
    -- CI-D: the governance plane routes to the sealed type-change verbs (propose/vote/apply).
    IF v_canon = 'kernel.propose_change' THEN
      RETURN ckp.propose_change(v_proj, p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.vote' THEN
      RETURN ckp.vote(p_payload) || jsonb_build_object('req', req);
    ELSIF v_canon = 'kernel.apply' THEN
      RETURN ckp.apply(p_payload) || jsonb_build_object('req', req);
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'governance_plane_unavailable',
      'plane', 'governance', 'verb', p_verb, 'canonical', v_canon)
      || jsonb_build_object('req', req);
  -- Tier 2 (3/3b): a governed query affordance (SPARQL text sealed via the governance plane,
  -- compiled into ckp.plans at apply) routes here. The caller binds typed params only; the query
  -- text is the kernel's OWN sealed fact, never caller input.
  ELSIF v_aff->>'plane' = 'query' THEN
    RETURN ckp.run_query_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  -- Scoring-loop layer 3: a governed DERIVED-read affordance ({formula, scope} sealed via the
  -- governance plane, compiled into ckp.plans at apply) routes here. The caller binds only the
  -- concept; the formula is the kernel's OWN sealed fact. Returns the band-less {ok, value,
  -- scored, freshness} envelope — the role-floor-reachable read surface the scoring client calls.
  ELSIF v_aff->>'plane' = 'derived' THEN
    RETURN ckp.run_derived_affordance(v_canon, p_payload) || jsonb_build_object('req', req);
  END IF;
  -- CI-E-5: instance.query is the typed derived-QueryShape read (the legacy instances.list alias
  -- keeps its list behavior below — routed by the ORIGINAL verb, not the shared canonical).
  IF p_verb = 'instance.query' THEN
    RETURN ckp.query(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.reach' THEN
    RETURN ckp.reach(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.transition' THEN
    RETURN ckp.transition(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.snapshot' THEN
    RETURN ckp.snapshot(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'concept.match' THEN
    RETURN ckp.concept_match(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.explain' THEN
    RETURN ckp.explain(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.retire' THEN
    RETURN ckp.retire(p_payload) || jsonb_build_object('req', req);
  ELSIF p_verb = 'instance.validate' THEN
    RETURN ckp.validate_instance(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 (v0.4.4): generic typed create. A uniform {type:<class IRI>, …fields} body
  -- routes to the §4 generic path, which seals it against the kernel's OWN declared shape.
  -- The discriminator is a TOP-LEVEL `type`: the legacy concretion forms carry no top-level
  -- `type` (task.create -> {task:{…}}, kernel.create -> {name:…}). `name` is NOT a usable
  -- discriminator here — it is a perfectly ordinary property on a generic type — so a `{task}`
  -- body still wins (the established concretion path) but everything else with a `type` is generic.
  ELSIF p_verb = 'instance.create'
        AND (p_payload ? 'type')
        AND NOT (p_payload ? 'task') THEN
    RETURN ckp.create_typed(p_payload) || jsonb_build_object('req', req);
  -- Tier 2 / v0.5 T4: generic typed update. instance.update with a `patch` sub-object patches
  -- by the type's declared properties (re-sealed); the legacy flat {id,…fields} form falls
  -- through to verb_to_legacy -> task.update.
  ELSIF p_verb = 'instance.update' AND (p_payload ? 'patch') THEN
    RETURN ckp.update_typed(p_payload) || jsonb_build_object('req', req);
  END IF;
  v_legacy := ckp.verb_to_legacy(p_verb, p_payload);

  CASE v_legacy

  -- ---- generic URN-addressed instance ops (the main goal) --------------
  WHEN 'instances.list', 'instances.last', 'instances.count', 'instance.get' THEN
    res := ckp._query(v_legacy, p_payload);

  -- ---- discovery -------------------------------------------------------
  -- B4: the surface in force, checked against the digests its epoch sealed.
  -- A READ, never a gate — a false positive here would take the substrate down,
  -- and legitimate drift exists. Findings name what was measured; empty = pass.
  WHEN 'surface.check' THEN
    res := ckp.surface_check(v_proj);

  -- B3: the store-level G-1 audit — the cross-node integrity body locality puts
  -- beyond the instance gate (§4.5). B1a: authority resolved by traversal, with
  -- an empty chain reported AS empty (persona spec §3).
  WHEN 'integrity.check' THEN
    res := ckp.integrity_check(v_proj);

  WHEN 'authority.mine' THEN
    res := ckp.authority_of(NULL);

  WHEN 'affordances' THEN
    -- B1 (pgCK#56): derived from SEALED ckp:Affordance instances of THIS kernel,
    -- carrying inShape resolved into a real input contract, retirement honoured,
    -- and the registry/sealed drift reported under `unsealed` rather than merged.
    -- Was: an unfiltered SPARQL scan of a graph nobody writes, which returned []
    -- for a substrate holding sealed affordances — reads as "no grants", means
    -- "nothing declared".
    res := ckp.affordances_of(v_proj);

  WHEN 'kernels.list' THEN
    res := jsonb_build_object('ok', true, 'kernels', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', COALESCE(body->>RL, regexp_replace(id,'^backlog:','')),
        'id', id, 'urn', 'ckp://Kernel#'||ckp._slug(COALESCE(body->>RL, regexp_replace(id,'^backlog:','')))) ORDER BY id)
      FROM ckp.instances WHERE body->>'type' = N||'Goal' AND id LIKE 'backlog:%'), '[]'::jsonb));

  WHEN 'provenance' THEN
    -- v0.4.15: id-form symmetry — resolve a bare-or-@id ref to the bare id the id-keyed
    -- tables use, so provenance(@id) is no longer a hollow envelope (matches reach/link/get).
    DECLARE tid text := ckp._resolve_id(p_payload->>'id');
    BEGIN
      res := jsonb_build_object('ok', true, 'id', tid, 'verified', ckp.verify(tid),
        'body', (SELECT body FROM ckp.instances WHERE id=tid),
        'proof', (SELECT jsonb_build_object('digest',digest,'method',method,'verified_at',verified_at) FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1),
        'ledger', COALESCE((SELECT jsonb_agg(jsonb_build_object('seq',seq,'prev_seq',prev_seq,'body_sha256',body_sha256,'ts',ts) ORDER BY seq) FROM ckp.ledger WHERE instance_id=tid),'[]'::jsonb));
    END;

  WHEN 'instance.verify' THEN
    res := jsonb_build_object('ok', true, 'id', p_payload->>'id', 'verified', ckp.verify(p_payload->>'id'));

  -- ---- participant input (kernel governs by sealing) -------------------
  WHEN 'participant.join' THEN
    res := jsonb_build_object('ok', true, 'sub', p_payload->>'name',
      'urn', 'urn:ckp:participant:'||ckp._slug(p_payload->>'name'));

  -- 0.4.43: germination as a GOVERNED act. kernel.create seals a board Goal and
  -- creates no kernel; the pgRDF route creates a correct kernel that belongs to
  -- nobody. This is the one that does both: client declares structure, substrate
  -- stamps ckp:ownedBy from the verified connection.
  WHEN 'kernel.germinate' THEN
    res := ckp.germinate_kernel(
             COALESCE(p_payload->>'project', p_payload->>'name'),
             p_payload->>'label',
             COALESCE(p_payload->>'projectKind', 'personal'));

  WHEN 'kernel.create' THEN
    DECLARE nm text := p_payload->>'name'; gid text;
    BEGIN
      IF nm IS NULL OR btrim(nm)='' THEN res := jsonb_build_object('ok',false,'error','kernel name required');
      ELSE
        gid := 'backlog:'||nm;
        PERFORM ckp.seal(gid, jsonb_build_object('type', N||'Goal', '@id', 'ckp://Goal#'||gid, N||'goal_id', gid,
          RL, nm, N||'title', nm, N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        res := jsonb_build_object('ok',true,'kernel',nm,'id',gid);
      END IF;
    END;

  WHEN 'task.create' THEN
    DECLARE t jsonb := p_payload->'task'; k text := p_payload->'task'->>'target_kernel';
            -- F-A (pgCK#9/#10): identity is SERVER-DERIVED from the verified connection
            -- (the ckp.requester GUC the trusted ingress sets from the NATS-verified bearer),
            -- NEVER the client payload. A payload {sub} is ignored — it cannot forge created_by.
            sub text := current_setting('ckp.requester', true); tid text; qseq int; v_body jsonb;
    BEGIN
      IF k IS NULL OR (p_payload->'task'->>'title') IS NULL THEN
        res := jsonb_build_object('ok',false,'error','kernel and title required');
      ELSE
        SELECT COALESCE(MAX((i.body->>(N||'queue_seq'))::int),0)+1 INTO qseq
          FROM ckp.instances i WHERE i.body->>(N||'target_kernel')=k AND i.body->>'type'=N||'Task';
        tid := 'task-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        v_body := jsonb_build_object('type', N||'Task', '@id', 'ckp://Task#'||tid, N||'task_id', tid,
          N||'title', t->>'title', N||'part_of_goal', 'backlog:'||k, N||'target_kernel', k,
          N||'lifecycle_state', COALESCE(t->>'lifecycle_state','planned'),
          N||'priority', COALESCE(t->'priority','5'::jsonb), N||'queue_seq', to_jsonb(qseq),
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN
          v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub),
                                             'participant', jsonb_build_object('sub', sub));
        END IF;
        PERFORM ckp.seal(tid, v_body);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  WHEN 'task.update' THEN
    DECLARE tid text := p_payload->>'id'; cur jsonb; v_fld text;
    BEGIN
      SELECT body INTO cur FROM ckp.instances WHERE id=tid;
      IF cur IS NULL THEN res := jsonb_build_object('ok',false,'error','instance not found');
      ELSE
        cur := cur - 'participant';
        -- Apply EVERY patchable task field the caller sent (closed allow-list = the task
        -- model's mutable properties; never arbitrary keys), preserving JSON type with ->
        -- not ->> so a number stays a number end-to-end. Pre-0.4.3 this hardcoded only
        -- lifecycle_state + priority — it silently dropped title (CK.Lib.Js report 2.1) and
        -- ->> coerced priority 1 → "1" (report 2.2).
        FOREACH v_fld IN ARRAY ARRAY['title','priority','lifecycle_state','part_of_goal','target_kernel'] LOOP
          IF p_payload ? v_fld THEN
            cur := cur || jsonb_build_object(N||v_fld, p_payload->v_fld);
          END IF;
        END LOOP;
        PERFORM ckp.seal(tid, cur);
        res := jsonb_build_object('ok',true,'id',tid,'verified',ckp.verify(tid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=tid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- board snapshot (web protocol verb the browser surfaces use) -------
  WHEN 'snapshot.board' THEN
    res := jsonb_build_object('ok', true,
      'kernels', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', i.body->>(N||'title'), 'id', i.id)
                    ORDER BY i.body->>(N||'title')), '[]'::jsonb)
                  FROM ckp.instances i WHERE i.body->>'type' = N||'Goal'),
      'tasks', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', i.id,
                  'title', i.body->>(N||'title'),
                  'target_kernel', i.body->>(N||'target_kernel'),
                  'part_of_goal', i.body->>(N||'part_of_goal'),
                  'lifecycle_state', i.body->>(N||'lifecycle_state'),
                  'priority', i.body->(N||'priority'),
                  'queue_seq', i.body->(N||'queue_seq'),
                  'created_by', i.body->>(N||'created_by'),
                  'proof_digest', (SELECT p.digest FROM ckp.proof p WHERE p.about = i.id ORDER BY p.id DESC LIMIT 1),
                  'verified', ckp.verify(i.id))
                  ORDER BY i.body->>(N||'target_kernel'), NULLIF(i.body->>(N||'queue_seq'),'')::int), '[]'::jsonb)
                FROM ckp.instances i WHERE i.body->>'type' = N||'Task'));

  -- ---- raw instance bodies — bulk replay for CKHexStore + corpus capture ---
  -- returns the literal IRI-keyed JSON-LD bodies (with @id + type), the shape a
  -- browser quad store ingests and a fixture corpus records (SPEC.CK.HEXSTORE Q4).
  WHEN 'snapshot.bodies' THEN
    DECLARE k text := p_payload->>'kernel';
    BEGIN
      res := jsonb_build_object('ok', true,
        'bodies', (SELECT coalesce(jsonb_agg(i.body ORDER BY i.id), '[]'::jsonb)
                   FROM ckp.instances i
                   WHERE k IS NULL OR i.body->>(N||'target_kernel') = k));
    END;

  -- ---- concept link (Edge) — captured so the structure is recoverable ---
  WHEN 'edge.create' THEN
    DECLARE src text := p_payload->>'source'; pred text := p_payload->>'predicate';
            tgt text := p_payload->>'target'; eid text; topic text;
            v_dpred jsonb := ckp.declared_predicates(v_proj);   -- T2: declared predicate set
    BEGIN
      IF src IS NULL OR pred IS NULL OR tgt IS NULL THEN
        res := jsonb_build_object('ok',false,'error','source, predicate, target required');
      ELSIF src = tgt THEN
        res := jsonb_build_object('ok',false,'error','no self-loops (v3.7 Edge rule)');
      -- T2 (v0.4.9): when the kernel declares predicates, the link predicate MUST be one of them;
      -- a kernel that declares none stays permissive (back-compat).
      ELSIF jsonb_array_length(v_dpred) > 0 AND NOT (v_dpred @> to_jsonb(pred)) THEN
        res := jsonb_build_object('ok',false,'error','undeclared_predicate','predicate',pred,'declared',v_dpred);
      ELSE
        eid := 'edge:'||src||'.'||pred||'.'||tgt;
        topic := 'link.'||pred||'.'||src||'.'||tgt;
        PERFORM ckp.seal(eid, jsonb_build_object('type', N||'Edge', '@id', 'ckp://Edge#'||eid,
          N||'source', src, N||'predicate', pred, N||'target', tgt, N||'topic', topic,
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
        -- Tier 2 (3/3a): also materialize the traversable quad so instance.reach finds
        -- this participant-created link (the Edge instance alone is not traversable).
        res := jsonb_build_object('ok',true,'id',eid,'topic',topic,'verified',ckp.verify(eid),
          'reachable', ckp.materialize_edge(src, pred, tgt, v_proj));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- a message over a link (the automated pigeon) — sealed = recoverable
  WHEN 'notify' THEN
    DECLARE frm text := p_payload->>'from'; tgt text := p_payload->>'to';
            pred text := COALESCE(p_payload->>'predicate','notifies');
            -- F-A: server-derived identity (verified connection), never the payload (see task.create).
            bdy text := p_payload->>'body'; sub text := current_setting('ckp.requester', true); mid text; topic text; v_body jsonb;
    BEGIN
      IF frm IS NULL OR tgt IS NULL OR bdy IS NULL THEN
        res := jsonb_build_object('ok',false,'error','from, to, body required');
      ELSE
        mid := 'msg-'||(extract(epoch from clock_timestamp())*1e9)::bigint::text;
        topic := 'link.'||pred||'.'||frm||'.'||tgt;
        v_body := jsonb_build_object('type', N||'Message', '@id', 'ckp://Message#'||mid,
          N||'from', frm, N||'to', tgt, N||'predicate', pred, N||'body', bdy, N||'topic', topic,
          N||'created_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        IF sub IS NOT NULL THEN v_body := v_body || jsonb_build_object(N||'created_by','urn:ckp:participant:'||ckp._slug(sub)); END IF;
        PERFORM ckp.seal(mid, v_body);
        res := jsonb_build_object('ok',true,'id',mid,'topic',topic,'verified',ckp.verify(mid),
          'proof_digest',(SELECT digest FROM ckp.proof WHERE about=mid ORDER BY id DESC LIMIT 1));
      END IF;
    EXCEPTION WHEN OTHERS THEN res := jsonb_build_object('ok',false,'error',SQLERRM);
    END;

  -- ---- unknown verb = the Tier-2 tool-delegation seam ------------------
  ELSE
    res := jsonb_build_object('ok', false, 'delegate', true,
      'error', 'verb not governed in-kernel: '||p_verb);
  END CASE;

  RETURN res || jsonb_build_object('req', req);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.register_derived_affordance(p_prop jsonb, p_project text, p_epoch integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_detail  jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_verb    text  := v_detail->>'verb';
  v_formula text  := v_detail->>'formula';
  v_scope   jsonb := v_detail->'scope';
  v_name_re text  := '^[a-z][a-z0-9_.]*$';
BEGIN
  IF v_verb IS NULL OR v_verb !~ v_name_re THEN
    RAISE EXCEPTION 'add_derived_affordance: verb must be a safe dotted name, got %', v_verb; END IF;
  IF v_formula IS NULL OR length(btrim(v_formula)) < 1 THEN
    RAISE EXCEPTION 'add_derived_affordance: formula required'; END IF;
  IF v_scope IS NULL OR v_scope->>'type' IS NULL OR v_scope->>'about_prop' IS NULL THEN
    RAISE EXCEPTION 'add_derived_affordance: scope {type, about_prop} required'; END IF;

  -- COMPILE: the sealed {formula, scope} becomes the plan for (kernel, verb, epoch).
  INSERT INTO ckp.plans(kernel, verb, epoch, plan)
  VALUES ('pgck', v_verb, p_epoch,
          jsonb_build_object('kind', 'derived', 'formula', v_formula, 'scope', v_scope))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='derived'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES ('pgck', v_verb, 'input.kernel.pgck.action.'||v_verb, 'derived', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'derived', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.register_query_affordance(p_prop jsonb, p_project text, p_epoch integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_detail  jsonb := COALESCE(p_prop->'proposalDetail', '{}'::jsonb);
  v_verb    text  := v_detail->>'verb';
  v_query   text  := v_detail->>'query';
  v_params  jsonb := COALESCE(v_detail->'params', '[]'::jsonb);
  v_name_re text  := '^[a-z][a-z0-9_.]*$';   -- verb + param NAME gate (lowercase dotted ids)
  v_p       text;
BEGIN
  IF v_verb IS NULL OR v_verb !~ v_name_re THEN
    RAISE EXCEPTION 'add_affordance: verb must be a safe dotted name, got %', v_verb; END IF;
  IF v_query IS NULL OR length(btrim(v_query)) < 1 THEN
    RAISE EXCEPTION 'add_affordance: query text required'; END IF;
  IF jsonb_typeof(v_params) <> 'array' THEN
    RAISE EXCEPTION 'add_affordance: params must be a JSON array of names'; END IF;
  FOR v_p IN SELECT jsonb_array_elements_text(v_params) LOOP
    IF v_p !~ v_name_re THEN RAISE EXCEPTION 'add_affordance: unsafe param name %', v_p; END IF;
  END LOOP;

  -- COMPILE: the sealed query becomes the plan for (kernel, verb, epoch). §5.3 made real.
  INSERT INTO ckp.plans(kernel, verb, epoch, plan)
  VALUES ('pgck', v_verb, p_epoch,
          jsonb_build_object('kind', 'sparql', 'statement', v_query, 'params', v_params))
  ON CONFLICT (kernel, verb, epoch) DO UPDATE SET plan = EXCLUDED.plan, compiled_at = now();

  -- REGISTER: dispatch resolves the verb via plane='query'.
  INSERT INTO ckp.affordance_registry(kernel, verb, in_topic, plane, epoch)
  VALUES ('pgck', v_verb, 'input.kernel.pgck.action.'||v_verb, 'query', p_epoch)
  ON CONFLICT (kernel, verb) DO UPDATE SET plane = 'query', epoch = EXCLUDED.epoch, refreshed_at = now();

  RETURN v_verb;
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.run_derived_affordance(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan    jsonb;
  v_epoch   bigint;
  v_formula text;
  v_scope   jsonb;
  v_concept text := p_payload->>'concept';
  v_val_re  text := '^[A-Za-z0-9 ._:#/-]*$';   -- concept VALUE gate (no quote/brace/backslash)
  v_res     jsonb;
  wm_now    bigint;
  wm_ph     bigint;
BEGIN
  SELECT plan, epoch INTO v_plan, v_epoch FROM ckp.plans
    WHERE kernel = 'pgck' AND verb = p_verb ORDER BY epoch DESC LIMIT 1;
  IF v_plan IS NULL OR v_plan->>'kind' <> 'derived' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_derived_affordance', 'verb', p_verb); END IF;
  IF v_concept IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'param', 'concept'); END IF;
  IF v_concept !~ v_val_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'param', 'concept'); END IF;

  v_formula := v_plan->>'formula';
  v_scope   := (v_plan->'scope') || jsonb_build_object('about', v_concept);   -- bind the concept

  v_res  := ckp.derived_sum(v_concept, v_scope, v_formula, v_epoch);
  wm_now := ckp._source_watermark(v_scope);
  SELECT watermark INTO wm_ph FROM ckp.phenotype_ptr WHERE concept = v_concept;

  RETURN jsonb_build_object(
    'ok', true, 'verb', p_verb,
    'value', (v_res->>'value')::numeric,
    'scored', true,
    'freshness', jsonb_build_object('watermark', wm_ph, 'current', wm_now,
                                    'fresh', COALESCE(wm_ph >= wm_now, false)));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION ckp.run_query_affordance(p_verb text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_plan   jsonb;
  v_stmt   text;
  v_params jsonb;
  v_val_re text := '^[A-Za-z0-9 ._:#/-]*$';   -- param VALUE gate: no quote/brace/backslash/?-var
  v_name   text;
  v_val    text;
  v_rows   jsonb;
BEGIN
  -- latest-epoch plan for this governed verb (a stale epoch is simply superseded).
  SELECT plan INTO v_plan FROM ckp.plans
   WHERE kernel = 'pgck' AND verb = p_verb ORDER BY epoch DESC LIMIT 1;
  IF v_plan IS NULL OR v_plan->>'kind' <> 'sparql' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_query_affordance', 'verb', p_verb); END IF;

  v_stmt   := v_plan->>'statement';
  v_params := COALESCE(v_plan->'params', '[]'::jsonb);

  -- bind each declared param: the caller supplies a VALUE only; validate it, then substitute
  -- into the author's `$name$` placeholder (placed in string-literal positions by the query).
  FOR v_name IN SELECT jsonb_array_elements_text(v_params) LOOP
    v_val := p_payload->>v_name;
    IF v_val IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_param', 'param', v_name); END IF;
    IF v_val !~ v_val_re THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_param', 'param', v_name); END IF;
    v_stmt := replace(v_stmt, '$' || v_name || '$', v_val);
  END LOOP;

  -- run the GOVERNED query — the text is a sealed kernel fact; only validated values were bound.
  SELECT jsonb_agg(j) INTO v_rows FROM pgrdf.sparql(v_stmt) j;
  RETURN jsonb_build_object('ok', true, 'verb', p_verb,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'rows', COALESCE(v_rows, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;
-- Repoint the routing surface onto the canonical name. Idempotent: a substrate
-- installed from the corrected baseline already seeds 'pgck' and matches zero
-- rows here.
DELETE FROM ckp.affordance_registry r
 WHERE r.kernel = 'pgck'
   AND EXISTS (SELECT 1 FROM ckp.affordance_registry o
                WHERE o.kernel = 'pgCK' AND o.verb = r.verb);

UPDATE ckp.affordance_registry
   SET kernel   = 'pgck',
       in_topic = replace(in_topic,  'input.kernel.pgCK.', 'input.kernel.pgck.'),
       out_topic= replace(out_topic, 'event.kernel.pgCK.', 'event.kernel.pgck.')
 WHERE kernel = 'pgCK';

DELETE FROM ckp.kernel_epoch e
 WHERE e.kernel = 'pgck'
   AND EXISTS (SELECT 1 FROM ckp.kernel_epoch o WHERE o.kernel = 'pgCK');

UPDATE ckp.kernel_epoch SET kernel = 'pgck' WHERE kernel = 'pgCK';
