-- s70_kernel_planes_agree.sql — THE WIRE PLANE AND THE SEAL PLANE NAME THE SAME KERNEL (0.4.78).
--
-- WHY THIS EXISTS. s63 claim (d) already asserts the SEEDED REGISTRY names only
-- the canonical kernel form. Nothing asserted the same of the GUC the TRANSPORT
-- reads — `pgck.kernels`, from which the auth-callout mints every event/result/
-- input subject grant. Measured 2026-08-20: no test in this suite or in
-- scripts/ ever read that GUC, and pgCK shipped a compiled-in default of
-- `pgCK` — a spelling its OWN canonicalizer refuses:
--
--   project.resolve {"segment":"pgCK"} on a fresh install ->
--     refused: "kernel id 'pgCK' is not canonical, no sealed kernel carries it
--      and no kernel graph stands behind it ... use 'pgck'.
--      (ckp.germinate_kernel refuses the same name; this door now applies the
--       same rule, so a fact can never be sealed into a project that could not
--       be germinated.)"
--
-- So the callout minted grants on `input.kernel.pgCK.…` while the substrate
-- could never seal into that project. It LOOKED healthy on any bench where a
-- canonical twin happened to be sealed, because clause-2 twin resolution
-- rescued it — the composer's four-spelling defect family, this time inside a
-- compiled default. Found downstream by oci-germination while burning
-- ck-allinone v0.7.33, where a bundle naming its kernel twice sent the two
-- planes apart: seals landed in `demo` while the wire served `pgck`, so a
-- VERIFIED client was correctly refused a type the surface it reached did not
-- admit, while the adopted surface emitted sealed events on a subject no
-- client had permission to hear. Both halves are decorative-constraint
-- defects: a value that governs the wire, consulted by no gate.
--
-- The four claims:
--   (a) FORM — every segment in `pgck.kernels` is canonical form. A NATS
--       subject is case-sensitive, so an uppercase segment is a surface no
--       conforming client can address.
--   (b) SUBSTRATE JUDGMENT — every such segment is canonical BY THE
--       CANONICALIZER, not merely resolvable. `canonical:false` fails even
--       when clause-2 twin resolution would rescue it: a wire plane that works
--       only because a twin happens to be sealed is an accident, and the
--       accident disappears on a fresh install (where it refuses outright).
--   (c) AGREEMENT — the kernel the wire serves and the kernel dispatch seals
--       into resolve to the SAME project. This is the v0.7.33 defect.
--   (d) NEGATIVE CONTROL — the same check, run against a deliberately
--       non-canonical segment, MUST fail. A check that cannot fail the thing
--       it claims is not a check (R1) — and this suite went green for the
--       entire life of the defect precisely because nothing looked here.
\set ON_ERROR_STOP 1

-- (a) + (b): every segment the transport serves, on both planes.
DO $$
DECLARE
  v_raw   text := current_setting('pgck.kernels', true);
  CANON   text := '^[a-z0-9]+(-[a-z0-9]+)*$';
  v_seg   text;
  v_prev  text := current_setting('ckp.project', true);
  v_res   text;
  v_n     int := 0;
BEGIN
  -- An unset GUC is the no-NATS build; nothing to serve, nothing to assert.
  IF v_raw IS NULL OR btrim(v_raw) = '' THEN
    RAISE NOTICE 's70: pgck.kernels unset (non-NATS build) — (a)/(b) not applicable';
  ELSE
    FOREACH v_seg IN ARRAY string_to_array(v_raw, ',') LOOP
      v_seg := btrim(v_seg);
      CONTINUE WHEN v_seg = '';
      v_n := v_n + 1;

      -- (a) FORM
      IF v_seg !~ CANON THEN
        RAISE EXCEPTION 's70 FAIL (a): pgck.kernels serves the non-canonical segment % — '
          'NATS subjects are case-sensitive, so the callout mints grants on a subject '
          'no conforming client can address and no fact can be sealed under. Canonical '
          'form is one transport segment, lowercase, dashes optional.', quote_literal(v_seg);
      END IF;

      -- (b) SUBSTRATE JUDGMENT — ask the canonicalizer itself, never a copy of its
      -- rules. ckp._project() is the ONE resolver the seal path calls, so its answer
      -- IS the seal-side verdict. Two failure modes, both fatal to the wire:
      --   * it RAISES        -> nothing can ever be sealed under this segment
      --   * it returns OTHER -> clause-2 twin resolution rescued a non-canonical
      --                         name; grants are minted for a segment whose facts
      --                         land under a different project
      -- (Note for future readers: the `canonical` boolean belongs to the DOOR verb
      -- project.resolve, not to this internal — an earlier draft of this test read
      -- it here, where it does not exist, and could never pass.)
      PERFORM set_config('ckp.project', v_seg, true);
      BEGIN
        v_res := ckp._project();
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 's70 FAIL (b): pgck.kernels serves %, which the canonicalizer '
          'REFUSES — no fact can ever be sealed under the segment the callout mints '
          'grants for. Substrate said: %', quote_literal(v_seg), SQLERRM;
      END;
      IF v_res IS DISTINCT FROM v_seg THEN
        RAISE EXCEPTION 's70 FAIL (b): pgck.kernels serves % but the canonicalizer '
          'resolves it to % — the wire plane works only because a canonical twin '
          'happens to be sealed (clause-2 rescue). That accident is absent on a fresh '
          'install, where the same segment refuses outright.',
          quote_literal(v_seg), quote_literal(v_res);
      END IF;
    END LOOP;

    IF v_n = 0 THEN
      RAISE EXCEPTION 's70 FAIL (a): pgck.kernels parsed to zero segments — the assertion would pass vacuously';
    END IF;
    RAISE NOTICE 's70 (a)(b) PASS — % wire segment(s) canonical on both planes', v_n;
  END IF;

  PERFORM set_config('ckp.project', COALESCE(v_prev, ''), true);
END $$;

-- (c) AGREEMENT: the wire's first segment and the seal path resolve to one project.
DO $$
DECLARE
  v_raw  text := current_setting('pgck.kernels', true);
  v_wire text;
  v_prev text := current_setting('ckp.project', true);
  v_seal text;
BEGIN
  IF v_raw IS NULL OR btrim(v_raw) = '' THEN
    RAISE NOTICE 's70 (c): pgck.kernels unset — not applicable';
    RETURN;
  END IF;
  v_wire := btrim(split_part(v_raw, ',', 1));

  -- What the seal path would resolve for that same segment (the relay sets
  -- ckp.project from the transport segment, so this IS the seal-side answer).
  PERFORM set_config('ckp.project', v_wire, true);
  v_seal := ckp._project();
  PERFORM set_config('ckp.project', COALESCE(v_prev, ''), true);

  IF v_seal IS DISTINCT FROM v_wire THEN
    RAISE EXCEPTION 's70 FAIL (c): PLANES DISAGREE — the wire serves % while the seal '
      'path resolves %. Grants are minted for one kernel and facts land in another: a '
      'verified client is refused types the surface it reached does not admit, while the '
      'adopted surface emits sealed events on a subject no client may hear (ck-allinone '
      'v0.7.33). One constant must write both planes.',
      quote_literal(v_wire), quote_literal(v_seal);
  END IF;
  RAISE NOTICE 's70 (c) PASS — wire and seal planes both resolve %', v_seal;
END $$;

-- (d) NEGATIVE CONTROL: the (a)+(b) check must FAIL a non-canonical segment.
-- Runs the identical two assertions against 'pgCK' — the exact shipped default
-- this test was written for. If either passes, the check above proves nothing.
DO $$
DECLARE
  CANON  text := '^[a-z0-9]+(-[a-z0-9]+)*$';
  v_bad  text := 'pgCK';
  v_prev text := current_setting('ckp.project', true);
  v_res  text;
  v_why  text;
BEGIN
  IF v_bad ~ CANON THEN
    RAISE EXCEPTION 's70 FAIL (d): the FORM check accepted % — it cannot fail what it claims to catch', quote_literal(v_bad);
  END IF;

  -- The (b) check, run against the exact shipped-and-fixed default. It must fail
  -- one of the two ways: refuse outright (fresh install), or resolve to a DIFFERENT
  -- project (twin rescue on a germinated bench). Passing identity is the one
  -- outcome that would prove (b) vacuous.
  PERFORM set_config('ckp.project', v_bad, true);
  BEGIN
    v_res := ckp._project();
  EXCEPTION WHEN OTHERS THEN
    v_res := NULL;                       -- refused: the control fired, as designed
    v_why := SQLERRM;
  END;
  PERFORM set_config('ckp.project', COALESCE(v_prev, ''), true);

  IF v_res IS NOT DISTINCT FROM v_bad THEN
    RAISE EXCEPTION 's70 FAIL (d): the canonicalizer resolved % to ITSELF — either the '
      'canonical rule moved or this control is now vacuous, and (b) proves nothing.',
      quote_literal(v_bad);
  END IF;
  RAISE NOTICE 's70 (d) PASS — negative control caught %: %',
    quote_literal(v_bad),
    COALESCE('refused ('||left(v_why, 60)||'…)', 'resolved away to '||quote_literal(v_res));
END $$;

SELECT 's70_kernel_planes_agree: PASS';
