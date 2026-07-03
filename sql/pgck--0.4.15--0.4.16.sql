-- pgck 0.4.15 -> 0.4.16 — governed ε-materialize substrate (Motion A.5, Model A).
--
-- A plan-declared, epoch-triggered materialize of a derived phenotype so a sealed
-- governed read can SUM a value the SPARQL engine cannot derive in-plan. GENERIC:
-- it evaluates a *sealed opaque* per-item formula, serving any kernel (net + dispersion)
-- without the substrate containing the consumer's math. Reuses seal->ledger->epoch (source),
-- SPI + the bgworker (compute), and pgrdf graph writes (store). No consumer term appears here.
--
-- v0.4.16 lands T1-T4 (substrate MVP): phenotype tables + generic MAX(ckp.ledger.seq)
-- watermark (T1); host-side materialize of the sealed formula (T2); three-clause freshness
-- + atomic committed-complete pointer (T3); ckp.derived_sum generic net read (T4).
-- Design: _WIP/SPEC.PGCK.EPSILON-MATERIALIZE.v0.2. Watermark/freshness are pure ckp.*
-- (pgRDF has no monotonic sequence); pgRDF only does the final SUM(?c) read + graph writes.

CREATE SCHEMA IF NOT EXISTS ckp;

-- Atomic committed-complete pointer: exactly one row per concept names the current
-- phenotype graph. The upsert on the `concept` PK is the swap — a reader resolving via
-- this pointer sees the previous complete graph until this single row flips (never torn).
CREATE TABLE IF NOT EXISTS ckp.phenotype_ptr (
  concept text PRIMARY KEY, graph_iri text NOT NULL, epoch bigint NOT NULL,
  watermark bigint NOT NULL, valid_until timestamptz, built_at timestamptz NOT NULL DEFAULT now());

-- Durable over-budget job: carries the scope + sealed formula so the bgworker can complete
-- a handed-off build at the CURRENT (epoch, watermark). One row per concept (latest wins).
CREATE TABLE IF NOT EXISTS ckp.materialize_job (
  concept text PRIMARY KEY, scope jsonb NOT NULL, formula text NOT NULL,
  epoch bigint NOT NULL, watermark bigint NOT NULL,
  phase text NOT NULL DEFAULT 'queued', enqueued_at timestamptz NOT NULL DEFAULT now());

-- T1 — substrate-generic evidence watermark: MAX(ckp.ledger.seq) over the declared scope.
-- Pure pgCK; never pgRDF (no monotonic seq there). The ledger high-water (not a triple/quad
-- count) is what catches a retract-then-reassert within an epoch. Scope names the item type
-- and the property holding the concept ref (about_prop) + its value (about) — no consumer term.
CREATE OR REPLACE FUNCTION ckp._source_watermark(p_scope jsonb)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(MAX(l.seq),0)::bigint
  FROM ckp.ledger l JOIN ckp.instances i ON i.id = l.instance_id
  WHERE (p_scope->>'type'  IS NULL OR i.body->>'type' = p_scope->>'type')
    AND (p_scope->>'about' IS NULL OR i.body->>(p_scope->>'about_prop') = p_scope->>'about')
$$;

-- T2 — GENERIC host-side materialize. p_formula is a SEALED governed SQL-expression over the
-- item row alias `i` (ckp.instances); the substrate SUBSTITUTES it, never contains it. Trust
-- model = run_query_affordance's sealed SPARQL: the formula is the kernel's own sealed fact,
-- never caller input. Writes signed :contrib + absolute :contrib_abs into a per-(ε,watermark)
-- graph; the genotype is untouched. Idempotent under the per-scope advisory lock.
CREATE OR REPLACE FUNCTION ckp._epsilon_materialize(
  p_concept text, p_scope jsonb, p_formula text, p_epoch bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  MP   text := 'urn:ckp:mat/';
  wm   bigint := ckp._source_watermark(p_scope);
  giri text := 'urn:ckp:phenotype/'||ckp._slug(p_concept)||'/'||p_epoch||'/'||wm;
  ttl  text := '';
  sqltext text;
  r record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_concept||':'||p_epoch||':'||wm, 0));
  IF EXISTS (SELECT 1 FROM ckp.phenotype_ptr WHERE concept=p_concept AND epoch=p_epoch AND watermark=wm) THEN
    RETURN (SELECT graph_iri FROM ckp.phenotype_ptr WHERE concept=p_concept);
  END IF;
  -- evaluate the sealed formula per in-scope item (dynamic SQL over the sealed expression)
  sqltext := format(
    'SELECT i.id AS id, (%s) AS c FROM ckp.instances i WHERE ($1->>''type'' IS NULL OR i.body->>''type''=$1->>''type'') '
    'AND ($1->>''about'' IS NULL OR i.body->>($1->>''about_prop'')=$1->>''about'')', p_formula);
  FOR r IN EXECUTE sqltext USING p_scope LOOP
    ttl := ttl || '<urn:ckp:mat:'||ckp._slug(r.id)||'> <'||MP||'contrib> "'||r.c
                || '"^^<http://www.w3.org/2001/XMLSchema#decimal> ; <'||MP||'contrib_abs> "'||abs(r.c)
                || '"^^<http://www.w3.org/2001/XMLSchema#decimal> . ';
  END LOOP;
  PERFORM pgrdf.parse_turtle(ttl, pgrdf.add_graph(giri), MP);
  RETURN giri;
END $$;
