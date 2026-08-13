-- pgck 0.4.55 — the retraction path minted undeclared keys and left the declared
-- state where it was.
--
-- ckp.retire wrote bare `retired` and `retired_reason`. Not IRIs at all, so they
-- entered the sealed body as undeclared predicates — the E3/R2 fail-open this
-- substrate exists to end, committed by the retraction path itself. And the
-- DECLARED property never moved: a retired Proposal kept ckp:proposalState
-- "pending" forever, so every other kernel reading the gated property saw
-- outstanding work that no longer existed.
--
-- Found from OUTSIDE by pgCK.MCP's ck_focus and filed as F15, with the right
-- reasoning: it counted those proposals as pending "because the declared property
-- is the only one another kernel can rely on". A retraction only a private key
-- records is not a retraction, it is a note.
--
-- Declared vocabulary only from here: ckp:retiredAtEpoch (already honoured by
-- ckp.affordances_of) + ckp:reason, and for a Proposal ckp:proposalState moves to
-- 'rejected' — an sh:in-gated enum, so a wrong value is refused by the gate rather
-- than accepted by me.
--
-- GENERATED from sql/pgck-baseline.sql — install and upgrade are the same bytes.

CREATE OR REPLACE FUNCTION ckp.retire(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_id     text := p_payload->>'id';
  v_reason text := p_payload->>'reason';
  v_proj   text := ckp._project();
  v_epoch  int;
  v_body   jsonb;
  v_type   text;
BEGIN
  IF v_reason IS NULL OR length(btrim(v_reason)) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reason_required', 'id', v_id);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  -- Only a DECLARED retirement blocks a second one. A row carrying the bare
  -- pre-0.4.55 `retired` key and no ckp:retiredAtEpoch was never retired in any
  -- way another kernel can read, so letting the sanctioned verb finish the act is
  -- COMPLETING it, not repeating it and not backfilling it — nothing is invented,
  -- the declared property is simply moved to where the private key already said
  -- it was. This is what lets F15's two observed rows close instead of standing
  -- as scars that every reader has to be told about.
  IF v_body ? (C||'retiredAtEpoch') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_retired', 'id', v_id,
      'reason', COALESCE(v_body->>(C||'reason'), v_body->>'retired_reason'));
  END IF;
  -- 0.4.55 — RETIREMENT NOW MOVES THE DECLARED PROPERTY, AND STOPS MINTING KEYS.
  --
  -- This wrote bare `retired` and `retired_reason` — not IRIs at all, so they
  -- entered the body as undeclared predicates, which is the E3/R2 fail-open this
  -- substrate exists to end, committed by the retraction path itself. Worse, the
  -- DECLARED state never moved: a retired Proposal kept ckp:proposalState
  -- "pending" forever, so every other kernel reading the gated property saw
  -- outstanding work that no longer existed.
  --
  -- pgCK.MCP found it from outside and filed it as F15, and its reasoning is the
  -- correct one: it counted those proposals as pending "because the declared
  -- property is the only one another kernel can rely on". A retraction that only
  -- a private key records is not a retraction — it is a note.
  --
  -- Declared vocabulary only, from here:
  --   ckp:retiredAtEpoch  integer, already honoured by ckp.affordances_of
  --   ckp:reason          string, the same property FailedMaterialization carries
  --   ckp:proposalState   for a Proposal, moved to 'rejected' — the enum is
  --                       (pending applied rejected) and it is sh:in-GATED, so if
  --                       this value were wrong the seal would refuse and say so.
  --
  -- The retraction stays a sealed fact: body' carries it, the seal appends ledger
  -- + proof, every prior body stays in the chain. Nothing is ever unsealed.
  v_epoch := COALESCE((SELECT epoch FROM ckp.kernel_epoch WHERE kernel = v_proj), 0);
  v_type  := v_body->>'type';
  v_body  := v_body || jsonb_build_object(
               C||'retiredAtEpoch', to_jsonb(v_epoch),
               C||'reason', btrim(v_reason));
  IF v_type = C||'Proposal' THEN
    v_body := v_body || jsonb_build_object(C||'proposalState', 'rejected');
  END IF;
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id,
    'retiredAtEpoch', v_epoch,
    'declaredStateMoved', (v_type = C||'Proposal'),
    'reason', btrim(v_reason), 'verified', ckp.verify(v_id));
END;
$function$
;

-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
