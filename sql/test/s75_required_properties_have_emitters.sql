-- s75_required_properties_have_emitters.sql — THE AUDIT THAT WOULD HAVE CAUGHT 0.4.88.
--
-- WHY THIS EXISTS. Constraints gate the SEAL. Nothing gated the question one layer up:
--
--     for every sh:minCount >= 1 property on every sh:targetClass,
--     WHICH EMISSION PATH PRODUCES IT?
--
-- That question had no instrument, so on 2026-08-28 ckp:transportSegment was added to
-- ckp:KernelShape with minCount 1 and the substrate's OWN germination path could not
-- satisfy it. The law blocked its own front door, fleet-wide, for four days. Every
-- existing gate stayed green because each tested ONE plane: the constraint was proven,
-- the path that must satisfy it was never exercised.
--
-- WHAT THIS IS NOT. It is not a claim of full coverage. The substrate emits a handful of
-- classes; the surface declares many more, most of them written by callers whose payloads
-- this gate cannot see. Reporting those as covered would be the vacuous pass this file
-- exists to kill. So each class lands in one of three buckets and the UNEXERCISED list is
-- printed every run, loudly, so nobody reads silence as coverage:
--
--   EXERCISED  — an emitter was run here and its output checked against the required set
--   UNEXERCISED— required properties exist; no emitter is wired into this gate yet
--   (none)     — the class has no required properties
--
-- FAILS when an EXERCISED emitter omits a property its own shape requires. That is the
-- 0.4.88 signature and the only condition under which a total write outage is silent.

\set ON_ERROR_STOP on

-- ─────────────────────────────────────────────────────────────────────────────
-- The required-property map, read from the composed surface the gate judges against.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW ckp._s75_required AS
WITH g AS (SELECT graph_id FROM pgrdf._pgrdf_graphs WHERE iri LIKE '%/shapes/composed' LIMIT 1),
d AS (SELECT id, lexical_value lv FROM pgrdf._pgrdf_dictionary),
q AS (SELECT subject_id s, predicate_id p, object_id o FROM pgrdf._pgrdf_quads
       WHERE graph_id = (SELECT graph_id FROM g)),
tc AS (SELECT q.s shape, dob.lv klass FROM q JOIN d dp ON dp.id=q.p JOIN d dob ON dob.id=q.o
        WHERE dp.lv='http://www.w3.org/ns/shacl#targetClass'),
pr AS (SELECT q.s shape, q.o pshape FROM q JOIN d dp ON dp.id=q.p
        WHERE dp.lv='http://www.w3.org/ns/shacl#property'),
pa AS (SELECT q.s pshape, dob.lv prop FROM q JOIN d dp ON dp.id=q.p JOIN d dob ON dob.id=q.o
        WHERE dp.lv='http://www.w3.org/ns/shacl#path'),
mc AS (SELECT q.s pshape, dob.lv mincount FROM q JOIN d dp ON dp.id=q.p JOIN d dob ON dob.id=q.o
        WHERE dp.lv='http://www.w3.org/ns/shacl#minCount' AND dob.lv ~ '^[0-9]+$')
SELECT tc.klass AS klass, pa.prop AS prop
  FROM tc JOIN pr ON pr.shape=tc.shape
          JOIN pa ON pa.pshape=pr.pshape
          JOIN mc ON mc.pshape=pr.pshape
 WHERE mc.mincount::int >= 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- (a) EXERCISED — ckp:Kernel via ckp.germinate_kernel. The path that broke.
--     Run the real emitter, then check its OWN output against its OWN required set.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT set_config('ckp.requester', 'svc:s75', false);
SELECT ckp.germinate_kernel('s75-probe', 'S75 Coverage Probe', 'shared') AS s75_emit;

DO $$
DECLARE
  v_body   jsonb;
  v_missing text[];
  r        record;
BEGIN
  SELECT ckp.dispatch('instance.get', jsonb_build_object('id','urn:ckp:s75-probe/kernel'))
           ->'instance'->'body' INTO v_body;

  IF v_body IS NULL THEN
    RAISE EXCEPTION E's75 FAIL (a): the emitter produced no readable instance — germination itself is broken, which this gate cannot distinguish from a coverage gap. Run s74 first; it isolates that.';
  END IF;

  v_missing := ARRAY[]::text[];
  FOR r IN SELECT prop FROM ckp._s75_required
            WHERE klass = 'https://conceptkernel.org/ontology/v3.11/core#Kernel'
  LOOP
    IF NOT (v_body ? r.prop) THEN
      v_missing := v_missing || r.prop;
    END IF;
  END LOOP;

  IF array_length(v_missing,1) > 0 THEN
    RAISE EXCEPTION E's75 FAIL (a): ckp.germinate_kernel does NOT emit % required propert(y/ies) of ckp:KernelShape:\n  %\nThis is the 0.4.88 signature: a shape requires what its own emitter cannot produce, so germination refuses itself on every door carrying this root — silently, because nobody germinates on an ordinary day. Fix the EMITTER. Never weaken the shape to make this pass.',
      array_length(v_missing,1), array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 's75 (a) PASS — ckp.germinate_kernel emits every required property of ckp:KernelShape (% checked)',
    (SELECT count(*) FROM ckp._s75_required WHERE klass='https://conceptkernel.org/ontology/v3.11/core#Kernel');
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (b) THE HONEST GAP — every class with required properties and no emitter here.
--     Printed every run. This is the backlog, not a pass.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE r record; n int := 0;
BEGIN
  RAISE NOTICE 's75 (b) UNEXERCISED — required properties whose emitter this gate does not run:';
  FOR r IN
    SELECT regexp_replace(klass,'^.*[#/]','') k, count(*) c
      FROM ckp._s75_required
     WHERE klass <> 'https://conceptkernel.org/ontology/v3.11/core#Kernel'
     GROUP BY 1 ORDER BY 1
  LOOP
    RAISE NOTICE '   % — % required', rpad(r.k, 22), r.c;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 's75 (b) % classes UNEXERCISED. Each is a 0.4.88 waiting to happen: a shape whose emitter nobody has checked. Wiring one emitter here converts one line of this list into a gate.', n;
END $$;

DROP VIEW ckp._s75_required;
SELECT 's75_required_properties_have_emitters: PASS (a) — see (b) for the standing gap';
