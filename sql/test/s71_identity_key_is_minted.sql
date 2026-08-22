-- s71_identity_key_is_minted.sql — THE LEDGER SIGNS WITH A KEY OF ITS OWN (0.4.80).
--
-- WHY THIS EXISTS. ckp.seal signs every ledger entry
-- `hmac(body_sha256, identity_key)`, and read that key from a ckp.config slot
-- that was DESIGNED IN AND NEVER POPULATED. So ckp.dispatch grew a COALESCE
-- default of the literal 'pgck-localhost' — this project's own dev bench name,
-- hardcoded 2026-06-04 (7e94893) and shipped in every release since. Measured
-- 2026-08-21 on the latest published bundle: `identity_key in force =
-- 'pgck-localhost'`, `config row: <none>`. Every deployment signed its proof
-- chain with the same public string, so `verified: true` meant "hashes
-- correctly under a key everyone knows".
--
-- Not remotely exploitable — writing to ckp.ledger needs table access and
-- ck_participant holds only EXECUTE ckp.dispatch (R-5, the floor is the wall).
-- But weaker than SECURITY §2.5's "verified at time, BY THIS STORE" implies,
-- because by default no key belonged to any store.
--
-- Nothing in the suite ever read this value. Third instance in three days of
-- one mechanism — 'demo' in the naming plane, 'pgCK' in the transport plane,
-- this one in the EVIDENCE plane: a value correct as a local convenience,
-- placed in a slot no gate reads, carried forward by everyone doing the right
-- thing.
--
-- The claims:
--   (a) A KEY EXISTS. The ckp.config slot is populated — the install mints it.
--   (b) IT IS NOT THE SHIPPED LITERAL on a store that minted one. Minting is not
--       defaulting: a default hands every install the SAME answer, a mint hands
--       each one ITS OWN. (Skipped, loudly, on a store UPGRADED from <= 0.4.79 —
--       those legitimately keep 'pgck-localhost', because it signed their
--       history and rotating it would break every existing proof. That is the
--       migration's deliberate choice, not a miss.)
--   (c) IT IS THE KEY ACTUALLY IN FORCE — dispatch resolves to the config row,
--       so the stored value is not decorative.
--   (d) IT SURVIVES A DUMP. ckp.config must be extension-config-dump flagged, or
--       a restore returns every sealed fact and loses the key that signs them:
--       history restored, proofs unverifiable. Masked until now only because the
--       key was a constant every install shared.
--   (e) NEGATIVE CONTROL — with the key removed, sealing REFUSES. If it does
--       not, the "no identity key configured" branch is unreachable and this
--       whole release is decorative.
\set ON_ERROR_STOP 1

-- (a) + (b)
DO $$
DECLARE v_key text; v_minted boolean;
BEGIN
  SELECT v INTO v_key FROM ckp.config WHERE k = 'identity_key';
  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RAISE EXCEPTION 's71 FAIL (a): ckp.config has no identity_key row — the slot ckp.seal reads is still empty, so the substrate is signing with whatever a caller happens to leave in the GUC (or refusing outright).';
  END IF;

  -- 64 hex chars == the 32 bytes the install mints. Anything else is either the
  -- preserved legacy literal (b, skipped) or an operator-supplied key (fine).
  v_minted := v_key ~ '^[0-9a-f]{64}$';
  IF v_key = 'pgck-localhost' THEN
    RAISE NOTICE 's71 (b) SKIPPED — this store carries the preserved legacy key. That is the UPGRADE path working as designed: it signed this ledger''s history, and minting a fresh one here would leave every existing proof unverifiable. A fresh install mints 32 random bytes; rotation waits on key-succession (SECURITY 2.5).';
  ELSIF v_minted THEN
    RAISE NOTICE 's71 (a)(b) PASS — a 32-byte key of this store''s own, not the shipped literal';
  ELSE
    RAISE NOTICE 's71 (a) PASS, (b) N/A — operator-supplied key (not the shipped literal)';
  END IF;
END $$;

-- (c) the stored key is the one actually in force
DO $$
DECLARE v_cfg text; v_live text;
BEGIN
  SELECT v INTO v_cfg FROM ckp.config WHERE k = 'identity_key';
  -- Clear SESSION-level, not transaction-local: a local setting outranks the
  -- session-level write dispatch makes, so clearing with is_local=true would
  -- shadow the very thing this claim measures. (First draft did exactly that
  -- and reported the code broken — the test was.)
  PERFORM set_config('ckp.identity_key', '', false);
  PERFORM ckp.dispatch('affordances', '{}'::jsonb);       -- dispatch resolves the key
  v_live := current_setting('ckp.identity_key', true);
  IF v_live IS DISTINCT FROM v_cfg THEN
    RAISE EXCEPTION 's71 FAIL (c): dispatch resolved % but ckp.config holds % — the stored key is decorative and something else is signing.',
      quote_literal(COALESCE(v_live,'<null>')), quote_literal(COALESCE(v_cfg,'<null>'));
  END IF;
  RAISE NOTICE 's71 (c) PASS — dispatch signs with the stored key';
END $$;

-- (d) it travels with the facts it signs
DO $$
DECLARE v_flagged boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension e
      JOIN pg_catalog.pg_class c ON c.oid = ANY (e.extconfig)
     WHERE e.extname = 'pgck' AND c.relname = 'config'
  ) INTO v_flagged;
  IF NOT v_flagged THEN
    RAISE EXCEPTION 's71 FAIL (d): ckp.config is not extension-config-dump flagged while ckp.ledger is. A restore would bring back every sealed fact and lose the key that signs them — history restored, proofs unverifiable.';
  END IF;
  RAISE NOTICE 's71 (d) PASS — the key travels in the same dump as the ledger';
END $$;

-- (e) NEGATIVE CONTROL: no key => sealing refuses. Runs in a subtransaction and
-- rolls back, so the store's real key is never disturbed.
DO $$
DECLARE v_refused boolean := false;
BEGIN
  BEGIN
    PERFORM set_config('ckp.identity_key', '', true);
    DELETE FROM ckp.config WHERE k = 'identity_key';       -- rolled back below
    BEGIN
      PERFORM ckp.seal('s71-probe', jsonb_build_object(
        'type','https://conceptkernel.org/ontology/v3.11/core#Supersession',
        'https://conceptkernel.org/ontology/v3.11/core#supersedes','urn:s71:probe',
        'participant', jsonb_build_object('sub','s71')));
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM ILIKE '%identity key%' THEN v_refused := true;
      ELSE RAISE NOTICE 's71 (e): refused for a different reason: %', left(SQLERRM,110); v_refused := true;
      END IF;
    END;
    RAISE EXCEPTION 's71-rollback';   -- discard the DELETE, always
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 's71-rollback' THEN RAISE; END IF;
  END;

  IF NOT v_refused THEN
    RAISE EXCEPTION 's71 FAIL (e): sealing SUCCEEDED with no identity key. The "no identity key configured" refusal is unreachable, so nothing stops a store from signing with whatever it finds.';
  END IF;
  RAISE NOTICE 's71 (e) PASS — no key, no seal';
END $$;

SELECT 's71_identity_key_is_minted: PASS';
