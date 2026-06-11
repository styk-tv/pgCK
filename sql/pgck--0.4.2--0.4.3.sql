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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;
