-- pgck 0.4.2 -> 0.4.3 — instance.retire (the spec's last unbuilt verb) + scratch-graph hygiene.
--
-- (a) CI follow-through: `instance.retire` was the one ⏳ row left in the FINALIZED
--     SPEC.CKP.v3.9 verb table ("retraction seal; you cannot unseal a sealed fact",
--     VISION §2.1). Retirement is a NEW sealed fact about the instance — the body gains
--     retired:true + the reason, the seal appends ledger + proof, and the original fact
--     remains forever in the chain. Nothing is deleted; nothing is unsealed.
-- (b) ckp.validate_report carried the same fixed-scratch-graph-id pattern
--     (1100000000 + pid) whose collision class already bit ckp.stage_ttl — a long-lived
--     store can mint auto-id graphs into that range, and add_graph(id, iri) then errors
--     "bound to a different IRI". Get-or-create BY IRI instead.
--
-- Include order: this file is chained BEFORE pgck_install_completeness (src/lib.rs) so
-- the closing floor pass still covers everything; SECDEF is ALSO declared inline on
-- every definition here (CREATE OR REPLACE resets security attributes — the 0.4.2 gotcha).

-- ============================================================================
-- §1 — instance.retire: the retraction seal
-- ============================================================================
CREATE OR REPLACE FUNCTION ckp.retire(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $retire$
DECLARE
  v_id     text := p_payload->>'id';
  v_reason text := p_payload->>'reason';
  v_body   jsonb;
BEGIN
  IF v_reason IS NULL OR length(btrim(v_reason)) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reason_required', 'id', v_id);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  IF COALESCE((v_body->>'retired')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_retired', 'id', v_id,
                              'retired_reason', v_body->>'retired_reason');
  END IF;
  -- The retraction is itself a sealed fact: body' carries the retirement; the seal
  -- appends ledger + proof; every prior body stays in the chain (cannot unseal).
  v_body := v_body || jsonb_build_object('retired', true, 'retired_reason', btrim(v_reason));
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'retired', true,
                            'reason', btrim(v_reason), 'verified', ckp.verify(v_id));
END;
$retire$;

COMMENT ON FUNCTION ckp.retire(jsonb) IS
  'instance.retire — the retraction seal (SPEC.CKP.v3.9 §4 / VISION §2.1): retirement is a '
  'NEW sealed fact (retired:true + reason); the original facts remain in the proof chain. '
  'The reason SHACL shape engages when the kernel declares it (constraints are facts).';

INSERT INTO ckp.affordance_registry (kernel, verb, in_topic, plane) VALUES
  ('pgCK','instance.retire','input.kernel.pgCK.action.instance.retire','instance')
ON CONFLICT (kernel, verb) DO UPDATE SET plane='instance';

ALTER FUNCTION ckp.retire(jsonb) OWNER TO ck_substrate;

-- ============================================================================
-- §2 — ckp.validate_report: scratch graph BY IRI (no fixed-id collisions)
-- ============================================================================
-- Body identical to CI-B-3 except the scratch acquisition: get-or-create by IRI
-- (stable per backend), never a fixed numeric id.
CREATE OR REPLACE FUNCTION ckp.validate_report(p_ttl text, p_shapes_graph integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $vreport$
DECLARE
  v_iri     text := 'urn:ckp:vreport-scratch:'||pg_backend_pid();
  v_scratch integer;
  v_report  jsonb;
BEGIN
  v_scratch := pgrdf.add_graph(v_iri);   -- get-or-create BY IRI (the stage_ttl fix, applied here)
  PERFORM pgrdf.clear_graph(v_scratch);
  PERFORM pgrdf.parse_turtle(p_ttl, v_scratch, 'urn:ckp:vreport#');
  v_report := ckp._validate(v_scratch, p_shapes_graph);   -- Ring-1: full sh:ValidationReport
  PERFORM pgrdf.clear_graph(v_scratch);
  RETURN jsonb_build_object(
    'conforms',   COALESCE((v_report->>'conforms')::boolean, false),
    'violations', COALESCE(v_report->'results', '[]'::jsonb));
END;
$vreport$;

COMMENT ON FUNCTION ckp.validate_report(text, integer) IS
  'CI-B-3 shape gate — { conforms, violations[] } from the engine sh:ValidationReport. '
  'v0.4.3: scratch graph acquired BY IRI (get-or-create), never a fixed numeric id.';

ALTER FUNCTION ckp.validate_report(text, integer) OWNER TO ck_substrate;

-- ============================================================================
-- §3 — Tier-1 consumer-block fixes (CK.Lib.Js npm-gate punch-list, 2026-06-12)
-- ============================================================================
-- Three verbs CK.Lib.Js observed broken on the live bundle, each fixed to match what the
-- substrate ACTUALLY does — never a richer claim than the seal enforces.

-- (a) instance.validate — registered with NO handler. The honest validate PREDICTS the seal: it
--     runs the SAME required-props (sh:minCount>=1) gate ckp.seal enforces against the project's
--     kernel graph, so `validate ok` ⟺ `seal will accept`. (Full all-constraint SHACL would reject
--     things seal accepts — wrong semantics for a pre-flight.) An unimported type = valid silence
--     (no shape → conforms), consistent with the v0.4.2 install-from-zero posture.
CREATE OR REPLACE FUNCTION ckp.validate_instance(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $vi$
DECLARE
  v_body    jsonb := COALESCE(p_payload->'body', p_payload);   -- accept {body:{…}} or the body itself
  v_type    text := v_body->>'type';
  v_proj    text := COALESCE(current_setting('ckp.project', true), 'demo');
  v_missing text;
BEGIN
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'type_required');
  END IF;
  SELECT string_agg(rp, ', ') INTO v_missing FROM (
    SELECT j->>'required_prop' AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE { GRAPH <urn:ckp:%s/kernel/ck> {
        ?s sh:targetClass <%s> ; sh:property ?p .
        ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1) } }
    $q$, v_proj, v_type)) AS j
  ) req
  WHERE NOT (v_body ? rp);
  RETURN jsonb_build_object('ok', true, 'type', v_type,
    'conforms', v_missing IS NULL,
    'missing_required', CASE WHEN v_missing IS NULL THEN '[]'::jsonb
                            ELSE to_jsonb(string_to_array(v_missing, ', ')) END);
END;
$vi$;
ALTER FUNCTION ckp.validate_instance(jsonb) OWNER TO ck_substrate;

-- (b) instance.transition state-key reconciliation. The gate read v3.8 `core#lifecycle_state` but
--     task.create writes v3.7 `lifecycle_state`, so a fresh task was always 'draft' to the gate.
--     Read the task model's own field first; write BOTH it and a bare 'state' so the board
--     projection and any reader see the new state. Map widened to the real task lifecycle.
INSERT INTO ckp.config(k,v) VALUES
  ('transition_map', '{"draft":["review"],"review":["approved","draft"],"approved":[],"planned":["in_progress","blocked"],"in_progress":["done","blocked","planned"],"blocked":["in_progress","planned"],"done":["in_progress"]}')
ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $trans$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.8/core#';
  N        text := 'https://conceptkernel.org/ontology/v3.7/';   -- task model ns (matches task.create)
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_body   jsonb; v_from text; v_allowed jsonb;
BEGIN
  IF v_to IS NULL OR v_to !~ '^[A-Za-z][A-Za-z0-9_-]*$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  -- read current state from the field the WRITER used: task model first, then bare 'state', then v3.8.
  v_from    := COALESCE(v_body->>(N||'lifecycle_state'), v_body->>'state', v_body->>(C||'lifecycle_state'), 'planned');
  v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
  IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                              'from', v_from, 'to', v_to, 'allowed', v_allowed);
  END IF;
  v_body := v_body || jsonb_build_object(N||'lifecycle_state', v_to, 'state', v_to);   -- write both
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to, 'verified', ckp.verify(v_id));
END;
$trans$;
ALTER FUNCTION ckp.transition(jsonb) OWNER TO ck_substrate;

-- (c) concept.match label field. It searched `body->>'rdfs:label'`; real Task/Goal instances carry
--     v3.7 `title`, no rdfs:label, so it always returned []. Compute the label from the actual
--     label-bearing fields once (still a sealed, pgCK-authored query; v_term auto-bound, no injection).
CREATE OR REPLACE FUNCTION ckp.concept_match(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $cm$
DECLARE
  v_term  text := p_payload->>'term';
  v_limit int  := LEAST(GREATEST(COALESCE((p_payload->>'limit')::int, 10), 1), 100);
  v_rows  jsonb;
BEGIN
  IF v_term IS NULL OR length(v_term) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_term', 'term', v_term);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'label', lbl, 'rank', rnk) ORDER BY rnk, lbl)
  INTO v_rows FROM (
    SELECT id, lbl,
      CASE WHEN lower(lbl) = lower(v_term)         THEN 1
           WHEN lower(lbl) LIKE lower(v_term)||'%' THEN 2
           ELSE 3 END AS rnk
    FROM (
      SELECT id, COALESCE(body->>'rdfs:label',
                          body->>'https://conceptkernel.org/ontology/v3.7/title',
                          body->>'title') AS lbl
      FROM ckp.instances
    ) s
    WHERE lbl ILIKE '%'||v_term||'%'
    ORDER BY rnk
    LIMIT v_limit
  ) t;
  RETURN jsonb_build_object('ok', true, 'term', v_term,
                            'count', COALESCE(jsonb_array_length(v_rows), 0),
                            'candidates', COALESCE(v_rows, '[]'::jsonb));
END;
$cm$;
ALTER FUNCTION ckp.concept_match(jsonb) OWNER TO ck_substrate;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
