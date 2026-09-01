-- pgck 0.4.95 -> 0.4.96
--
-- E-3 — BEING AN IRI IS NOT BEING DECLARED.
--
-- ckp.update_typed resolved patch keys by FORM. A key containing ':' was passed
-- straight through as "already a full IRI"; a bare key was checked against the
-- declared property map and refused if absent. So the same property was refused
-- in one spelling and accepted in the other:
--
--     patch {'weightNonsense': 0.5}                      -> undeclared_patch_key
--     patch {'https://…/core#weightNonsense': 0.5}       -> ACCEPTED, and lands
--                                                           on the sealed instance
--
-- Nothing downstream catches it. No shape targets a property that does not
-- exist, so the patched body conforms VACUOUSLY — admitted, ledgered,
-- proof-digested, and judged by nothing. This is precisely the trap the
-- composed-aware patch path was built to close, surviving inside it: a caller who
-- writes the namespace out can mint any property onto any sealed instance.
--
-- The check is by VALUE, because _propmap maps localname -> IRI, and it is
-- deliberately SKIPPED on an unshaped type: there is no declared contract to
-- check against there, and refusing would invent one the surface never made.
-- The refusal names the declared set, so it teaches rather than merely denying.
--
-- HOW IT WAS FOUND, because the method matters more than the fix. s81's control
-- (e) passed on its first run — but for the WRONG REASON: with no requester set,
-- ckp.seal refused the write as unattributed, which is a correct refusal and a
-- completely different one from the claim being made. The control asserted only
-- THAT it refused. Asserting WHY turned a green control red and exposed this.
-- A control that passes for the wrong reason is not a control.
--
-- Proof: tdd obligation E-3 (undeclared refused in BOTH forms, and a DECLARED
-- property in IRI form still accepted — the cure must be a gate, not a wall),
-- and s81 (e) now asserting the reason. C-4 flips GREEN with it, because a
-- projector whose out-of-range values are refused while its misspelled fields
-- are minted is only half a gate.

CREATE OR REPLACE FUNCTION ckp.update_typed(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ckp', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id      text := p_payload->>'id';
  v_patch   jsonb := p_payload->'patch';
  v_proj    text := ckp._project();
  v_cur     jsonb;
  v_type    text;
  v_ns      text;
  v_propmap jsonb;
  v_shaped  boolean;
  v_key     text;
  v_val     jsonb;
  v_keyiri  text;
BEGIN
  IF v_id IS NULL OR btrim(v_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'id_required'); END IF;
  IF v_patch IS NULL OR jsonb_typeof(v_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_patch', 'hint', 'instance.update generic form needs a {patch:{…}} object'); END IF;
  SELECT body INTO v_cur FROM ckp.instances WHERE id = v_id;
  IF v_cur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id); END IF;

  v_type := v_cur->>'type';
  v_ns   := CASE WHEN v_type ~ '[/#]' THEN regexp_replace(v_type, '[^/#]*$', '') ELSE '' END;

  -- declared property map for the instance's type (same read as create_typed).
  -- 0.4.51: composed-aware, because a patch is a WRITE and must resolve keys the
  -- same way the gate will judge them. Refusing an undeclared patch key earlier,
  -- with the declared set named, is strictly better than sealing it under the
  -- type's namespace and letting the gate refuse the whole body.
  v_propmap := ckp._propmap(v_type, v_proj);
  v_shaped := (v_propmap <> '{}'::jsonb);

  v_cur := v_cur - 'participant';   -- re-resolved by ckp.seal from any supplied claims

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    CONTINUE WHEN v_key IN ('id', 'type', '@id');   -- not patchable via this path
    IF position(':' in v_key) > 0 THEN
      -- 0.4.96 (E-3) — BEING AN IRI IS NOT BEING DECLARED.
      -- This branch passed any key containing ':' straight through on the
      -- strength of its FORM. The bare form was checked against the declared
      -- set and refused; the SAME property spelled as a full IRI was accepted.
      -- Measured: patch {'weightNonsense': …} refuses undeclared_patch_key,
      -- patch {'https://…core#weightNonsense': …} lands on the sealed instance.
      -- Nothing downstream catches it either — no shape targets a property that
      -- does not exist, so it conforms VACUOUSLY. That is the exact trap this
      -- composed-aware path was built to close, surviving inside it, and it was
      -- found only because a control that had been passing for the wrong reason
      -- was made to assert the reason.
      --
      -- The check is by VALUE, because _propmap maps localname -> IRI. On an
      -- UNSHAPED type it is deliberately skipped: there is no declared contract
      -- to check against, and refusing would invent one the surface never made.
      IF v_shaped AND NOT EXISTS (
           SELECT 1 FROM jsonb_each_text(v_propmap) m WHERE m.value = v_key) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type, 'form', 'absolute-iri',
                                  'hint', 'spelling the namespace out does not declare a property',
                                  'declared', (SELECT jsonb_agg(m.value ORDER BY m.value)
                                                 FROM jsonb_each_text(v_propmap) m));
      END IF;
      v_keyiri := v_key;                                    -- declared, in IRI form
    ELSIF v_shaped THEN
      IF v_propmap ? v_key THEN
        v_keyiri := v_propmap->>v_key;                      -- declared localname -> IRI
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'undeclared_patch_key',
                                  'key', v_key, 'type', v_type,
                                  'declared', (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_propmap) k));
      END IF;
    ELSE
      v_keyiri := v_ns || v_key;                            -- unshaped: namespace under the type's NS
    END IF;
    v_cur := v_cur || jsonb_build_object(v_keyiri, v_val);  -- `->` value: preserves number/bool/object
  END LOOP;

  -- re-seal: the required-props gate re-validates the patched body.
  PERFORM ckp.seal(v_id, v_cur);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'verified', ckp.verify(v_id),
    'proof_digest', (SELECT digest FROM ckp.proof WHERE about = v_id ORDER BY id DESC LIMIT 1))
    || ckp._stamped(v_id)
    || CASE WHEN NULLIF(current_setting('ckp.last_warnings', true), '') IS NOT NULL
            THEN jsonb_build_object('warnings', current_setting('ckp.last_warnings', true)::jsonb)
            ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$
;
