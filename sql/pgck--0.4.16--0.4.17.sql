-- pgck 0.4.16 -> 0.4.17 — ε-materialize completeness + hardening (Motion A.5, Model A).
--
-- Completes the v0.4.16 substrate MVP: the dispersion read (net + volume over the same
-- phenotype, T5), the over-budget bgworker handoff + phenotype GC (T6), and the within-ε /
-- non-intrusiveness end-to-end gate (T7, test-only). Still GENERIC — no consumer term; the
-- formula is a sealed opaque input. Design: _WIP/SPEC.PGCK.EPSILON-MATERIALIZE.v0.2.

CREATE SCHEMA IF NOT EXISTS ckp;

-- T5 — ckp.derived_dispersion: two proven-green SUMs over the SAME (ε, watermark) phenotype —
-- net (SUM :contrib) and volume (SUM :contrib_abs). The substrate returns net + volume only;
-- the consumer computes κ = 1 − |net|/volume and any contested threshold (those are the
-- consumer's, not substrate math). :contrib_abs must be a STORED fact because pgRDF cannot
-- SUM(ABS(?c)). Fresh-only, same (e1) synchronous path as ckp.derived_sum.
CREATE OR REPLACE FUNCTION ckp.derived_dispersion(p_concept text, p_scope jsonb, p_formula text, p_epoch bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE MP text := 'urn:ckp:mat/'; wm bigint := ckp._source_watermark(p_scope); giri text; net numeric; vol numeric;
BEGIN
  IF NOT ckp._phenotype_fresh(p_concept, p_epoch, wm) THEN
    giri := ckp._epsilon_materialize(p_concept, p_scope, p_formula, p_epoch);
    PERFORM ckp._phenotype_publish(p_concept, giri, p_epoch, wm, now()+interval '1 hour');
  END IF;
  giri := (SELECT graph_iri FROM ckp.phenotype_ptr WHERE concept=p_concept);
  -- SRF-in-COALESCE is disallowed; read each SUM in a scalar subquery (FROM), COALESCE the scalar.
  net := COALESCE((SELECT (j->>'v')::numeric FROM pgrdf.sparql(
        'SELECT (SUM(?c) AS ?v) WHERE { GRAPH <'||giri||'> { ?s <'||MP||'contrib> ?c } }') AS j), 0);
  vol := COALESCE((SELECT (j->>'v')::numeric FROM pgrdf.sparql(
        'SELECT (SUM(?c) AS ?v) WHERE { GRAPH <'||giri||'> { ?s <'||MP||'contrib_abs> ?c } }') AS j), 0);
  RETURN jsonb_build_object('ok',true,'net',net,'volume',vol);
END $$;

-- T6 — over-budget (e2) handoff: durably enqueue the build carrying scope + sealed formula so the
-- bgworker (src/materialize_drain.rs) can complete it at the CURRENT (ε, watermark). One row per
-- concept (latest supersedes). Returns the honest recompute_in_progress the client re-dispatches on.
CREATE OR REPLACE FUNCTION ckp.enqueue_materialize(p_concept text, p_scope jsonb, p_formula text, p_epoch bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE wm bigint := ckp._source_watermark(p_scope);
BEGIN
  INSERT INTO ckp.materialize_job(concept,scope,formula,epoch,watermark,phase)
  VALUES (p_concept,p_scope,p_formula,p_epoch,wm,'queued')
  ON CONFLICT (concept) DO UPDATE SET scope=EXCLUDED.scope, formula=EXCLUDED.formula,
    epoch=EXCLUDED.epoch, watermark=EXCLUDED.watermark, enqueued_at=now();
  RETURN jsonb_build_object('ok',true,'recompute_in_progress',true);
END $$;

-- T6 — phenotype GC: drop per-(ε,watermark) graphs the pointer no longer references (superseded).
CREATE OR REPLACE FUNCTION ckp._phenotype_gc() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int := 0; r record;
BEGIN
  FOR r IN SELECT g.iri FROM pgrdf._pgrdf_graphs g
           WHERE g.iri LIKE 'urn:ckp:phenotype/%' AND g.iri NOT IN (SELECT graph_iri FROM ckp.phenotype_ptr) LOOP
    PERFORM pgrdf.drop_graph(r.iri); n := n+1;
  END LOOP; RETURN n;
END $$;

-- T6 — bgworker drain body (called by src/materialize_drain.rs each tick). Completes ONE queued
-- job at the CURRENT (ε, watermark) — a job whose watermark was superseded rebuilds fresh, never
-- stale — publishes the atomic pointer, deletes the job. Non-blocking: FOR UPDATE SKIP LOCKED, so
-- a concurrent worker/read never waits. Returns 1 if a job was completed, 0 if the queue was empty.
-- (plpgsql, not a Rust CTE: an unreferenced SELECT CTE would not evaluate the materialize/publish.)
CREATE OR REPLACE FUNCTION ckp.materialize_drain_once() RETURNS int LANGUAGE plpgsql AS $$
DECLARE j record; giri text; wm bigint;
BEGIN
  SELECT concept, scope, formula, epoch INTO j
  FROM ckp.materialize_job ORDER BY enqueued_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN 0; END IF;
  wm   := ckp._source_watermark(j.scope);
  giri := ckp._epsilon_materialize(j.concept, j.scope, j.formula, j.epoch);
  PERFORM ckp._phenotype_publish(j.concept, giri, j.epoch, wm, now()+interval '1 hour');
  DELETE FROM ckp.materialize_job WHERE concept = j.concept;
  RETURN 1;
END $$;
