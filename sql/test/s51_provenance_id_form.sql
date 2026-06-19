-- s51_provenance_id_form.sql — v0.4.15 (id-form symmetry): provenance(bare) ≡ provenance(@id).
--
-- v0.4.14 made reach/link id-form-flexible, but instance.provenance kept keying body/proof/ledger/
-- verify by the bare id, so a client passing the @id / full-IRI (the form create returns + reach/link
-- accept, and the form CSVC addresses by) got a HOLLOW ok:true (null body/proof). v0.4.15 routes the
-- provenance `tid` through ckp._resolve_id (inverse of _resolve_ref). This asserts: provenance by the
-- BARE id is non-hollow (baseline), and provenance by the @id returns the SAME body + proof + verified.
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
DO $setup$ DECLARE g bigint; BEGIN g := pgrdf.add_graph('urn:ckp:s51-test/kernel/ck'); PERFORM pgrdf.clear_graph(g); END $setup$;
SET ckp.project = 's51-test';

-- create one instance; capture its BARE id (what create returns) + its stamped @id.
DO $mk$
DECLARE r jsonb; v_at text;
BEGIN
  SET LOCAL ROLE ck_participant;
  r := ckp.dispatch('instance.create', '{"type":"urn:ckp:s51-test/type/Note","label":"hello"}'::jsonb);
  RESET ROLE;
  IF (r->>'ok') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's51 FAIL (mk): create failed: %', r; END IF;
  SELECT body->>'@id' INTO v_at FROM ckp.instances WHERE id = r->>'id';
  PERFORM set_config('s51.id', r->>'id', false);   -- bare id
  PERFORM set_config('s51.at', v_at, false);        -- stamped @id
  IF position(':' in current_setting('s51.id')) > 0 THEN RAISE EXCEPTION 's51 FAIL: create id should be BARE: %', current_setting('s51.id'); END IF;
  IF current_setting('s51.at') IS NULL OR position(':' in current_setting('s51.at')) = 0 THEN
    RAISE EXCEPTION 's51 FAIL: @id should be an IRI: %', current_setting('s51.at'); END IF;
END $mk$;

-- provenance(bare) is non-hollow (baseline) AND provenance(@id) returns the SAME envelope (the fix).
DO $prov$
DECLARE pb jsonb; pa jsonb;
BEGIN
  SET LOCAL ROLE ck_participant;
  pb := ckp.dispatch('instance.provenance', jsonb_build_object('id', current_setting('s51.id')));
  pa := ckp.dispatch('instance.provenance', jsonb_build_object('id', current_setting('s51.at')));
  RESET ROLE;
  -- baseline: bare-id provenance is real
  IF pb->'body' IS NULL OR pb->'body' = 'null'::jsonb THEN RAISE EXCEPTION 's51 FAIL: provenance(bare) hollow: %', pb; END IF;
  IF (pb->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's51 FAIL: provenance(bare) not verified: %', pb; END IF;
  -- the fix: @id provenance must ALSO be non-hollow and EQUAL the bare form
  IF pa->'body' IS NULL OR pa->'body' = 'null'::jsonb THEN
    RAISE EXCEPTION 's51 FAIL: provenance(@id) is HOLLOW — _resolve_id not routed (D1 unfixed): %', pa; END IF;
  IF (pa->'body') IS DISTINCT FROM (pb->'body') THEN
    RAISE EXCEPTION 's51 FAIL: provenance(@id) body != provenance(bare) body'; END IF;
  IF (pa->'proof'->>'digest') IS DISTINCT FROM (pb->'proof'->>'digest') THEN
    RAISE EXCEPTION 's51 FAIL: provenance(@id) proof digest != provenance(bare)'; END IF;
  IF (pa->>'verified') IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 's51 FAIL: provenance(@id) not verified: %', pa; END IF;
END $prov$;

\echo s51_provenance_id_form: PASS
