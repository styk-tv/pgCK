-- s62 — P0-E (pgCK#28): the epoch is produced by a sealed, checkable Materialization.
--
-- The done-when, verbatim: "show me the sealed Materialization that produced this
-- epoch's action set, and re-derive that set from the shapes at that epoch." This
-- applies a governed change, finds the Materialization it produced, follows
-- producesEpoch to the Epoch resource, and RE-DERIVES the surface digest from the
-- shapes — asserting the sealed claim equals a fresh computation. Also asserts a
-- projectorless op is refused at propose (no inert 'applied').
--
-- Run (booted + kernel loaded by the smoke): psql … < s62_epoch_materialization.sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
CALL ckp.bootstrap_kernel();
INSERT INTO ckp.config(k,v) VALUES ('identity_key','demo-secret')
  ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;

-- (1) a projectorless op is REFUSED at propose — never sealed as inert 'applied'.
DO $noproj$
DECLARE res jsonb;
BEGIN
  res := ckp.dispatch('kernel.propose_change',
    '{"op":"set_quorum","about":"urn:ckp:demo/kernel/board","requires_quorum":1}'::jsonb);
  IF (res->>'ok') IS DISTINCT FROM 'false' OR (res->>'error') <> 'op_has_no_projector' THEN
    RAISE EXCEPTION 's62 FAIL: projectorless op must be refused at propose, got %', res;
  END IF;
END $noproj$;

-- (2) apply a projectored change and capture the epoch it produced.
CREATE TEMP TABLE IF NOT EXISTS s62 (epoch int);
TRUNCATE s62;
DO $apply$
DECLARE r jsonb; piri text;
BEGIN
  r := ckp.dispatch('kernel.propose_change',
    '{"op":"add_class","about":"urn:ckp:demo/kernel/board","requires_quorum":1,"detail":{"class":"urn:ckp:demo/type/S62Thing"}}'::jsonb);
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's62 FAIL: propose: %', r; END IF;
  piri := r->>'proposal_iri';
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about', piri, 'value','approve'));
  r := ckp.dispatch('kernel.apply', jsonb_build_object('about', piri));
  IF r->>'state' <> 'applied' THEN RAISE EXCEPTION 's62 FAIL: apply not applied: %', r; END IF;
  INSERT INTO s62 VALUES ((r->>'epoch')::int);
END $apply$;

-- (3) THE DONE-WHEN: the sealed Materialization produced that epoch, and its
--     surfaceDigest re-derives from the shapes at that epoch.
DO $check$
DECLARE
  e int := (SELECT epoch FROM s62);
  v_mat jsonb; v_epoch jsonb;
  C text := 'https://conceptkernel.org/ontology/v3.11/core#';
  v_mat_surf text; v_ep_surf text; v_ep_iri text; v_rederived text;
BEGIN
  -- the Materialization sealed for this epoch
  SELECT body INTO v_mat FROM ckp.instances
    WHERE body->>'type' = C||'Materialization' AND body->>(C||'toEpoch') = e::text;
  IF v_mat IS NULL THEN RAISE EXCEPTION 's62 FAIL: no sealed Materialization for epoch %', e; END IF;
  IF v_mat->>(C||'materializes') <> 'urn:ckp:demo/kernel/ck' THEN
    RAISE EXCEPTION 's62 FAIL: Materialization.materializes wrong: %', v_mat->>(C||'materializes'); END IF;
  v_mat_surf := v_mat->>(C||'surfaceDigest');
  v_ep_iri   := v_mat->>(C||'producesEpoch');
  IF v_ep_iri <> format('urn:ckp:demo/epoch/%s', e) THEN
    RAISE EXCEPTION 's62 FAIL: producesEpoch wrong: %', v_ep_iri; END IF;

  -- follow producesEpoch to the Epoch resource; it names the same surface
  SELECT body INTO v_epoch FROM ckp.instances WHERE body->>'@id' = v_ep_iri;
  IF v_epoch IS NULL THEN RAISE EXCEPTION 's62 FAIL: producesEpoch names no sealed Epoch (%)', v_ep_iri; END IF;
  IF (v_epoch->>(C||'epoch'))::int <> e THEN RAISE EXCEPTION 's62 FAIL: Epoch ordinal mismatch'; END IF;
  v_ep_surf := v_epoch->>(C||'surfaceDigest');
  IF v_ep_surf <> v_mat_surf THEN RAISE EXCEPTION 's62 FAIL: Epoch/Materialization surfaceDigest disagree'; END IF;

  -- RE-DERIVE the surface digest from the shapes at this epoch — the sealed
  -- claim must equal a fresh computation, or the digest is a trusted number.
  v_rederived := ckp._surface_digest(ckp._composed_shapes('demo'));
  IF v_rederived <> v_mat_surf THEN
    RAISE EXCEPTION 's62 FAIL: surfaceDigest not re-derivable — sealed % vs recomputed %', v_mat_surf, v_rederived;
  END IF;
  IF v_mat_surf !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 's62 FAIL: surfaceDigest not 64-hex: %', v_mat_surf; END IF;
END $check$;

\echo s62_epoch_materialization: PASS
