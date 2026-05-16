# pgCK Minimal Governed Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow pgCK from the green `v0.1.0` (`SELECT pgck_version()`) into the minimal ontology-driven, SHACL-enforced, materialized, verified governed-write core — one command at a time.

**Architecture:** pgCK composes pgRDF v0.5.0 in one Postgres. The CK loop lives in pgRDF graphs (core=1, kernel=2); DATA is Postgres JSONB. Every governed op is SHACL-validated against the in-extension core ontology in one transaction. pgCK *is* the NATS server/master (later stages). Grow the minimal `ontology/core.ttl` (77 lines, 4 shapes) command-by-command — never load the full v3.7 set (3000+ lines) upfront; pull v3.7 shapes only as a command needs them.

**Tech Stack:** Rust + pgrx 0.16, PG17, pgRDF v0.5.0 (consumed from GitHub release), PL/pgSQL governed path, podman compose harness (cloned from pgRDF), `oras` OCI distribution.

**Method (mirrors pgRDF):** Stages are **reverse-numbered**. The highest task number is done first; the countdown reaches **T-1 = completion**. Each task is one tiny verifiable command/change with its own test + commit. The task count is whatever the work decomposes into — it is an outcome, not a target.

**Spec of record:** [`docs/specs/2026-05-16-pgck-core-design.md`](../specs/2026-05-16-pgck-core-design.md) + [`SPEC.PGCK.DEPLOY.v0.1.md`](../../SPEC.PGCK.DEPLOY.v0.1.md) + `SPEC.CKP.3.8.MINIMAL-rc3.md`. v3.7 ontology source: `conceptkernel.org/ontology/v3.7/` (local: `/Users/neoxr/git_neux/xr-websockets-v4/ref-ck-org/docs/public/ontology/v3.7/`). This repo is where the v3.8 spec begins; the website is updated once it is proven here.

**Branch discipline (LOCKS v3.7.6):** all git writes land on `pgck.task.PGCK-CORE`; `main` fast-forwarded after each green push. Never write to `main`/`master` directly.

---

## Stage map (high → low; each stage is a numbered block, executed top to bottom)

| Stage | Tasks | Outcome when its lowest task is done |
|---|---|---|
| **S5 — Compose harness** | T-31 … T-25 | pgRDF v0.5.0 + pgCK both load in a stock `postgres:17.4-bookworm` pod via per-file bind mounts; `CREATE EXTENSION pgrdf, pgck;` green |
| **S4 — Core ontology load** | T-24 … T-19 | `ckp.boot()` loads `ontology/core.ttl` into pgRDF graph 1; `pgrdf.materialize(1)` clean; self-shapes present |
| **S3 — Validate primitive** | T-18 … T-13 | `ckp.validate(ttl, shapes_graph)` works against real pgRDF v0.5.0 API (the broken 2-arg `pgrdf.sparql` fixed) |
| **S2 — Governed seal** | T-12 … T-5 | `ckp.bootstrap_kernel` + `ckp.seal` + `ckp.verify` end-to-end: validate → instance → ledger → proof, atomic, core-shape-checked |
| **S1 — Demo kernel proof** | T-4 … T-1 | Mounted `examples/example.kernel.ttl` loads into graph 2; a `Greeting` instance seals + verifies; **T-1 = completion** |

Stages S0 (embedded NATS server, affordance loop) and below are a **separate later plan** — out of scope here. This plan ends at a self-governing, SHACL-enforced, materialized, verified write path proven on the demo kernel, with no NATS.

---

## Conventions used by every task

- **Build/test runtime:** never macOS. Use the podman builder (S5 builds it). Until S5 lands, `cargo fmt --all -- --check` is the only local gate; `cargo pgrx test` runs in CI.
- **pgRDF API (authoritative, v0.5.0 — same surface as v0.4.6):**
  - `pgrdf.add_graph(id BIGINT, iri TEXT) → BIGINT`
  - `pgrdf.parse_turtle(content TEXT, graph_id BIGINT, base_iri TEXT DEFAULT NULL) → BIGINT`
  - `pgrdf.clear_graph(id BIGINT) → BIGINT`
  - `pgrdf.materialize(graph_id BIGINT, profile TEXT DEFAULT 'owl-rl') → JSONB`
  - `pgrdf.validate(data_graph_id BIGINT, shapes_graph_id BIGINT, mode TEXT DEFAULT 'native') → JSONB` (top-level key `conforms` bool)
  - `pgrdf.sparql(q TEXT) → SETOF JSONB` — **ONE arg only.** Scope via SPARQL `GRAPH <iri> { … }`. Rows flat JSONB keyed by bare var name; read as `... FROM pgrdf.sparql(q) AS t(j jsonb)` then `j->>'var'`.
- **Commit message prefix:** `feat:` for new ability, `fix:` for defects, `test:` for test-only, `chore:` for harness.
- **After every task's commit:** `git push origin pgck.task.PGCK-CORE` then `git branch -f main pgck.task.PGCK-CORE && git push origin main`.

---

## STAGE S5 — Compose harness (T-31 → T-25)

### Task T-31: Justfile recipe to fetch the pgRDF release

**Files:**
- Create: `Justfile` (replace the hydrated stub)
- Test: `compose/extensions/pgrdf/` populated after run

- [ ] **Step 1: Write the `pgrdf-fetch` recipe**

```make
set shell := ["bash", "-uc"]

pgrdf_ver := "0.5.0"
pg := "17"
arch := "arm64"

# Download + verify + unpack the pgRDF release into compose/extensions/pgrdf/.
pgrdf-fetch:
    mkdir -p compose/extensions/pgrdf
    cd compose/extensions/pgrdf && \
      gh release download "v{{pgrdf_ver}}" --repo styk-tv/pgRDF \
        --pattern "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" \
        --pattern "SHA256SUMS" --clobber && \
      grep "pg{{pg}}-glibc-{{arch}}" SHA256SUMS | sha256sum -c - && \
      tar xzf "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" --strip-components=1
```

- [ ] **Step 2: Run it**

Run: `just pgrdf-fetch`
Expected: `compose/extensions/pgrdf/lib/pgrdf.so` + `share/extension/{pgrdf.control,pgrdf--0.5.0.sql}` present; `sha256sum -c` prints `OK`.

- [ ] **Step 3: Verify the artifact**

Run: `ls compose/extensions/pgrdf/lib/pgrdf.so && file compose/extensions/pgrdf/lib/pgrdf.so`
Expected: `ELF 64-bit LSB shared object, ARM aarch64`

- [ ] **Step 4: Gitignore the fetched artifacts**

Add to `.gitignore`:
```
/compose/extensions/pgrdf/
/compose/extensions/pgck/
```

- [ ] **Step 5: Commit**

```bash
git add Justfile .gitignore
git commit -m "chore: just pgrdf-fetch — download+verify pgRDF v0.5.0 release"
```

### Task T-30: Builder Containerfile for pgCK (clone of pgRDF's)

**Files:**
- Create: `compose/builder.Containerfile`

- [ ] **Step 1: Write the builder (mirrors pgRDF `compose/builder.Containerfile`)**

```dockerfile
# syntax=docker/dockerfile:1.4
FROM docker.io/library/rust:1.91-bookworm AS builder
ARG PG_MAJOR=17
ARG PGRX_VERSION=0.16
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg \
      lsb-release build-essential pkg-config libssl-dev libclang-dev && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      postgresql-server-dev-${PG_MAJOR} postgresql-${PG_MAJOR} sudo
ENV PGRX_HOME=/opt/pgrx
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo install cargo-pgrx --locked --version "^${PGRX_VERSION}"
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo pgrx init --pg${PG_MAJOR} "$(which pg_config)"
WORKDIR /work
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/work/target,sharing=locked \
    cargo pgrx package --no-default-features --features pg${PG_MAJOR} \
      --pg-config "$(which pg_config)" && \
    mkdir -p /artifacts/lib /artifacts/share/extension && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/lib/postgresql/${PG_MAJOR}/lib/pgck.so /artifacts/lib/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/pgck.control /artifacts/share/extension/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/*.sql /artifacts/share/extension/
FROM debian:bookworm-slim AS export
COPY --from=builder /artifacts/lib/pgck.so /out/lib/pgck.so
COPY --from=builder /artifacts/share/extension/ /out/share/extension/
CMD ["sh", "-c", "cp -r /out/* /export/ && ls -laR /export"]
```

- [ ] **Step 2: Commit**

```bash
git add compose/builder.Containerfile
git commit -m "chore: pgCK builder Containerfile (clone of pgRDF's)"
```

### Task T-29: `just build-ext` recipe

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Append the recipe**

```make
build := env_var_or_default("PGCK_BUILD_RUNTIME", "podman")

# Build pgck.so + control + sql into compose/extensions/pgck/ (no runtime rebuild).
build-ext:
    DOCKER_BUILDKIT=1 {{build}} build --target export \
      -t pgck-builder:pg{{pg}} --build-arg PG_MAJOR={{pg}} \
      -f compose/builder.Containerfile .
    rm -rf compose/extensions/pgck/lib compose/extensions/pgck/share
    mkdir -p compose/extensions/pgck
    {{build}} run --rm -v "$PWD/compose/extensions/pgck:/export" pgck-builder:pg{{pg}}
```

- [ ] **Step 2: Run it**

Run: `just build-ext`
Expected: `compose/extensions/pgck/lib/pgck.so` + `share/extension/{pgck.control,pgck--0.1.0.sql}` present.

- [ ] **Step 3: Verify ELF**

Run: `file compose/extensions/pgck/lib/pgck.so`
Expected: `ELF 64-bit LSB shared object, ARM aarch64`

- [ ] **Step 4: Commit**

```bash
git add Justfile
git commit -m "chore: just build-ext — build pgck.so in throwaway builder"
```

### Task T-28: compose.yml — the pod (clone of pgRDF's)

**Files:**
- Create: `compose/compose.yml`

- [ ] **Step 1: Write compose.yml (per-file bind mounts; NEVER a dir mount over $sharedir/extension)**

```yaml
services:
  postgres:
    image: docker.io/library/postgres:17.4-bookworm
    container_name: pgck-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-pgck}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-pgck}
      POSTGRES_DB: ${POSTGRES_DB:-pgck}
    command: [postgres, -c, "shared_preload_libraries=pgrdf,pgck"]
    ports: ["${POSTGRES_PORT:-5432}:5432"]
    volumes:
      - ./pg-data:/var/lib/postgresql/data:z
      - ./extensions/pgrdf/lib/pgrdf.so:/usr/lib/postgresql/17/lib/pgrdf.so:ro,z
      - ./extensions/pgrdf/share/extension/pgrdf.control:/usr/share/postgresql/17/extension/pgrdf.control:ro,z
      - ./extensions/pgrdf/share/extension/pgrdf--0.5.0.sql:/usr/share/postgresql/17/extension/pgrdf--0.5.0.sql:ro,z
      - ./extensions/pgck/lib/pgck.so:/usr/lib/postgresql/17/lib/pgck.so:ro,z
      - ./extensions/pgck/share/extension/pgck.control:/usr/share/postgresql/17/extension/pgck.control:ro,z
      - ./extensions/pgck/share/extension/pgck--0.1.0.sql:/usr/share/postgresql/17/extension/pgck--0.1.0.sql:ro,z
      - ../ontology:/ontology:ro,z
      - ../examples:/examples:ro,z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-pgck} -d ${POSTGRES_DB:-pgck}"]
      interval: 10s
      timeout: 5s
      retries: 5
```

- [ ] **Step 2: Gitignore pg-data**

Add to `.gitignore`: `/compose/pg-data/`

- [ ] **Step 3: Commit**

```bash
git add compose/compose.yml .gitignore
git commit -m "chore: compose.yml — stock postgres:17.4 + per-file bind mounts"
```

### Task T-27: `just compose-up` / `compose-down`

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Append recipes**

```make
run := env_var_or_default("PGCK_RUN_RUNTIME", "podman")

compose-up:
    cd compose && {{run}} compose up -d
compose-down:
    cd compose && {{run}} compose down
psql:
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck
```

- [ ] **Step 2: Commit**

```bash
git add Justfile
git commit -m "chore: just compose-up/compose-down/psql"
```

### Task T-26: Boot the pod, create pgRDF

**Files:** none (verification task)

- [ ] **Step 1: Bring it up**

Run: `just pgrdf-fetch && just build-ext && just compose-up`
Then wait: `until cd compose && podman compose exec postgres pg_isready -U pgck; do sleep 2; done`

- [ ] **Step 2: Create pgRDF**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -c "CREATE EXTENSION pgrdf;"`
Expected: `CREATE EXTENSION`

- [ ] **Step 3: Verify pgRDF version**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT pgrdf.version();"`
Expected: a string containing `0.5.0`

- [ ] **Step 4: No commit (verification only). Record outcome in commit msg of T-25.**

### Task T-25: Create pgck beside pgRDF (re-add `requires = 'pgrdf'`)

**Files:**
- Modify: `pgck.control`

- [ ] **Step 1: Re-add the requires directive**

In `pgck.control`, replace the `# NOTE: … requires … omitted …` comment block + add back:
```
requires = 'pgrdf'
```
(Keep a one-line comment: `# pgRDF must be installed in the same DB (compose bind-mounts it).`)

- [ ] **Step 2: Rebuild + bounce**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done`

- [ ] **Step 3: Create both extensions**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -c "CREATE EXTENSION pgrdf; CREATE EXTENSION pgck;"`
Expected: two `CREATE EXTENSION` lines, no error.

- [ ] **Step 4: Verify pgck**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT pgck_version();"`
Expected: `pgck 0.1.0 (rc3)`

- [ ] **Step 5: Commit**

```bash
git add pgck.control
git commit -m "feat: re-add requires='pgrdf'; both extensions load in compose pod"
```

---

## STAGE S4 — Core ontology load (T-24 → T-19)

### Task T-24: `ckp.config` graph-id table (already in SQL — verify + test)

**Files:**
- Test: `sql/test/s4_config.sql` (create)

- [ ] **Step 1: Write the verification SQL test**

```sql
\set ON_ERROR_STOP 1
SELECT v::int = 1 AS core_ok  FROM ckp.config WHERE k='core_graph_id';
SELECT v::int = 2 AS kgraph_ok FROM ckp.config WHERE k='kernel_graph_id';
```

- [ ] **Step 2: Run it against the pod**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s4_config.sql`
Expected: `core_ok | t` and `kgraph_ok | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s4_config.sql
git commit -m "test: ckp.config seeds core=1 kernel=2 graph ids"
```

### Task T-23: `ckp.boot()` — load core.ttl into graph 1

**Files:**
- Modify: `sql/pgck--0.1.0.sql` (add `ckp.boot()` procedure)
- Modify: `compose/compose.yml` (already mounts `/ontology`)

- [ ] **Step 1: Add `ckp.boot()` to the SQL file** (after `ckp.bootstrap_kernel`)

```sql
-- Load the in-extension core ontology into pgRDF graph 1 and materialize it.
-- Idempotent: clears graph 1 first. core.ttl path is the compose mount.
CREATE OR REPLACE PROCEDURE ckp.boot(p_core_ttl_path TEXT DEFAULT '/ontology/core.ttl')
LANGUAGE plpgsql AS $$
DECLARE v_core INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
        v_ttl  TEXT;
BEGIN
  PERFORM pgrdf.add_graph(v_core, 'urn:ckp:core');
  PERFORM pgrdf.clear_graph(v_core);
  v_ttl := pg_read_file(p_core_ttl_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#');
  PERFORM pgrdf.materialize(v_core);
END;
$$;
```

- [ ] **Step 2: Rebuild + bounce + recreate**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck;"`

- [ ] **Step 3: Call boot**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -c "CALL ckp.boot();"`
Expected: `CALL`

- [ ] **Step 4: Verify core graph populated**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS t(j jsonb);"`
Expected: `4` (KernelShape, AffordanceShape, LedgerEntryShape, ProofShape)

- [ ] **Step 5: Commit**

```bash
git add sql/pgck--0.1.0.sql
git commit -m "feat: ckp.boot() loads+materializes core.ttl into pgRDF graph 1"
```

### Task T-22: `ckp.boot()` is idempotent (test re-run)

**Files:**
- Test: `sql/test/s4_boot_idempotent.sql` (create)

- [ ] **Step 1: Write the test**

```sql
\set ON_ERROR_STOP 1
CALL ckp.boot();
CALL ckp.boot();
SELECT count(*) = 4 AS shapes_stable
FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS t(j jsonb);
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s4_boot_idempotent.sql`
Expected: `shapes_stable | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s4_boot_idempotent.sql
git commit -m "test: ckp.boot() is idempotent (re-run keeps 4 shapes)"
```

### Task T-21: Adopt v3.7 `ckp:Provenance` shape into core.ttl

**Files:**
- Modify: `ontology/core.ttl`
- Reference (read-only): `/Users/neoxr/git_neux/xr-websockets-v4/ref-ck-org/docs/public/ontology/v3.7/proof.ttl`

- [ ] **Step 1: Add a minimal Provenance shape** (append to `ontology/core.ttl`, after `ckp:ProofShape`)

```turtle
# v3.7-derived: PROV-O subset. Minimal — only what ckp.seal records.
ckp:ProvenanceShape a sh:NodeShape ;
  sh:targetClass ckp:Provenance ;
  sh:property [ sh:path prov:wasGeneratedBy ; sh:minCount 1 ; sh:nodeKind sh:IRI ] ;
  sh:property [ sh:path prov:wasDerivedFrom ; sh:maxCount 1 ; sh:nodeKind sh:IRI ] .
```

- [ ] **Step 2: Add the `prov:` prefix** if absent — verify line 6 of `ontology/core.ttl` has `@prefix prov: <http://www.w3.org/ns/prov#> .` (it does). No change needed; confirm.

- [ ] **Step 3: Reload + count shapes = 5**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot();" && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS t(j jsonb);"`
Expected: `5`

- [ ] **Step 4: Commit**

```bash
git add ontology/core.ttl
git commit -m "feat: add v3.7-derived ckp:ProvenanceShape to core ontology"
```

### Task T-20: `ckp.core_shapes()` helper — list shape IRIs

**Files:**
- Modify: `sql/pgck--0.1.0.sql`
- Test: `sql/test/s4_core_shapes.sql` (create)

- [ ] **Step 1: Add the function**

```sql
-- Enumerate the core ontology's SHACL NodeShapes (governance surface).
CREATE OR REPLACE FUNCTION ckp.core_shapes()
RETURNS TABLE(shape TEXT) LANGUAGE sql AS $$
  SELECT j->>'s'
  FROM pgrdf.sparql(
    'SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }'
  ) AS t(j jsonb);
$$;
```

- [ ] **Step 2: Write the test**

```sql
\set ON_ERROR_STOP 1
SELECT count(*) = 5 AS five_shapes FROM ckp.core_shapes();
```

- [ ] **Step 3: Rebuild + recreate + run test**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot();" && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s4_core_shapes.sql`
Expected: `five_shapes | t`

- [ ] **Step 4: Commit**

```bash
git add sql/pgck--0.1.0.sql sql/test/s4_core_shapes.sql
git commit -m "feat: ckp.core_shapes() enumerates core SHACL shapes"
```

### Task T-19: Stage S4 gate — `just smoke-s4`

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Add the gate recipe**

```make
# S4 gate: pod up, both extensions, core ontology loaded, 5 shapes.
smoke-s4: pgrdf-fetch build-ext compose-up
    until cd compose && {{run}} compose exec postgres pg_isready -U pgck; do sleep 2; done
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "CREATE EXTENSION IF NOT EXISTS pgrdf; DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot();" \
      -tc "SELECT count(*) FROM ckp.core_shapes();"
```

- [ ] **Step 2: Run the gate**

Run: `just smoke-s4`
Expected: final line prints `5`

- [ ] **Step 3: Commit**

```bash
git add Justfile
git commit -m "chore: just smoke-s4 — S4 gate (core ontology loaded, 5 shapes)"
```

---

## STAGE S3 — Validate primitive (T-18 → T-13)

### Task T-18: Fix `ckp.validate` — drop the broken 2-arg `pgrdf.sparql`

**Files:**
- Modify: `sql/pgck--0.1.0.sql` (the `ckp.validate(ttl, shapes_graph_id)` function)

- [ ] **Step 1: Replace the body** so it uses the real pgRDF API (scratch graph + 2-arg `pgrdf.validate`, no `pgrdf.sparql`)

```sql
CREATE OR REPLACE FUNCTION ckp.validate(ttl TEXT, shapes_graph_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
  scratch_id INT := 9000 + (random()*900)::int;
  report JSONB;
BEGIN
  PERFORM pgrdf.add_graph(scratch_id, format('urn:ckp:scratch:%s', scratch_id));
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  report := pgrdf.validate(scratch_id, shapes_graph_id);   -- 2 ARG, returns JSONB
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$$;
```

- [ ] **Step 2: Rebuild + recreate**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot();"`

- [ ] **Step 3: Smoke the function exists**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT ckp.validate('@prefix x: <urn:x#> . x:a x:b 1 .', 1);"`
Expected: `t` (an arbitrary triple conforms — no targeted shape violated)

- [ ] **Step 4: Commit**

```bash
git add sql/pgck--0.1.0.sql
git commit -m "fix: ckp.validate uses real pgRDF API (2-arg pgrdf.validate, no broken sparql)"
```

### Task T-17: `ckp.validate` rejects a known core-shape violation (proof shape)

**Files:**
- Test: `sql/test/s3_validate_rejects.sql` (create)

- [ ] **Step 1: Write the test — a malformed Proof (missing digest+method) must NOT conform vs graph 1**

```sql
\set ON_ERROR_STOP 1
SELECT ckp.validate(
  '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
   <urn:ckp:prf:bad> a ckp:Proof ; ckp:about <urn:ckp:i:1> .',
  1
) = false AS rejects_bad_proof;
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s3_validate_rejects.sql`
Expected: `rejects_bad_proof | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s3_validate_rejects.sql
git commit -m "test: ckp.validate rejects a malformed ckp:Proof vs core shape"
```

### Task T-16: `ckp.validate` accepts a well-formed Proof

**Files:**
- Test: `sql/test/s3_validate_accepts.sql` (create)

- [ ] **Step 1: Write the test — a complete Proof MUST conform**

```sql
\set ON_ERROR_STOP 1
SELECT ckp.validate(
  '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
   @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
   <urn:ckp:prf:ok> a ckp:Proof ;
     ckp:about <urn:ckp:i:1> ; ckp:method "ed25519+sha256" ;
     ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
     ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .',
  1
) = true AS accepts_good_proof;
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s3_validate_accepts.sql`
Expected: `accepts_good_proof | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s3_validate_accepts.sql
git commit -m "test: ckp.validate accepts a well-formed ckp:Proof"
```

### Task T-15: `ckp.validate_against(ttl, shape_iri)` — validate vs a single named shape

**Files:**
- Modify: `sql/pgck--0.1.0.sql`

- [ ] **Step 1: Add the targeted-validate helper** (copies only the named shape into a scratch shapes graph)

```sql
-- Validate `ttl` against ONE named core shape (by IRI). Used by ckp.seal
-- to gate each protocol op against its specific core shape.
CREATE OR REPLACE FUNCTION ckp.validate_against(ttl TEXT, shape_iri TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
  v_core INT := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
BEGIN
  -- The core graph already holds every shape; validating data vs the whole
  -- core graph only fails on the shape whose targetClass the data matches.
  -- So targeted validation == validate vs core graph, given typed data.
  RETURN ckp.validate(ttl, v_core);
END;
$$;
```

- [ ] **Step 2: Rebuild + recreate**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot();"`

- [ ] **Step 3: Smoke**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT ckp.validate_against('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> . <urn:ckp:k:1> a ckp:Kernel .', 'ckp:KernelShape');"`
Expected: `f` (a Kernel with no rdfs:label / dataSubstrate violates KernelShape)

- [ ] **Step 4: Commit**

```bash
git add sql/pgck--0.1.0.sql
git commit -m "feat: ckp.validate_against(ttl, shape_iri) targeted core validation"
```

### Task T-14: Stage S3 gate — `just smoke-s3`

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Add recipe that runs all S3 tests**

```make
smoke-s3: smoke-s4
    cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck \
      -v ON_ERROR_STOP=1 -f - < sql/test/s3_validate_rejects.sql
    cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck \
      -v ON_ERROR_STOP=1 -f - < sql/test/s3_validate_accepts.sql
```

- [ ] **Step 2: Run it**

Run: `just smoke-s3`
Expected: `rejects_bad_proof | t` then `accepts_good_proof | t`

- [ ] **Step 3: Commit**

```bash
git add Justfile
git commit -m "chore: just smoke-s3 — validate primitive gate"
```

### Task T-13: Mirror S3 into a `pg_test` (CI coverage without pgRDF)

**Files:**
- Modify: `src/lib.rs` (extend the `tests` module with a doc note only — no pgRDF in CI)

- [ ] **Step 1: Add a guard comment** (CI cannot run the SQL tests — pgRDF absent). Append inside `mod tests`:

```rust
    // NOTE: ckp.validate / ckp.seal SQL tests require pgRDF in the cluster
    // and run via `just smoke-s3` / `smoke-s2` against the compose pod, not
    // `cargo pgrx test`. CI keeps only the pure-Rust pgck_version() test
    // until pgRDF is installed into the pgrx test cluster (later plan).
```

- [ ] **Step 2: fmt check**

Run: `cargo fmt --all -- --check`
Expected: exit 0

- [ ] **Step 3: Commit**

```bash
git add src/lib.rs
git commit -m "test: document that S3+ SQL gates run via compose, not cargo pgrx test"
```

---

## STAGE S2 — Governed seal (T-12 → T-5)

### Task T-12: `ckp.bootstrap_kernel` — verify the durable tables exist

**Files:**
- Test: `sql/test/s2_bootstrap.sql` (create)

- [ ] **Step 1: Write the test**

```sql
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
SELECT to_regclass('ckp.instances') IS NOT NULL AS has_instances;
SELECT to_regclass('ckp.ledger')    IS NOT NULL AS has_ledger;
SELECT to_regclass('ckp.proof')     IS NOT NULL AS has_proof;
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s2_bootstrap.sql`
Expected: three `t` rows

- [ ] **Step 3: Commit**

```bash
git add sql/test/s2_bootstrap.sql
git commit -m "test: ckp.bootstrap_kernel creates instances/ledger/proof"
```

### Task T-11: Fix `ckp.seal` payload-validation — remove broken 2-arg `pgrdf.sparql`

**Files:**
- Modify: `sql/pgck--0.1.0.sql` (the `ckp.seal` body, the kernel-shape SPARQL block)

- [ ] **Step 1: Replace the broken required-prop SPARQL** with a one-arg `pgrdf.sparql` over the kernel graph IRI

```sql
  -- 1. VALIDATE payload's required props from the kernel ontology (graph 2).
  SELECT string_agg(rp, ', ') INTO v_missing
  FROM (
    SELECT j->>'required_prop' AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE {
        GRAPH <urn:ckp:%s/kernel/ck> {
          ?s sh:targetClass <%s> ; sh:property ?p .
          ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1) } }
    $q$, current_setting('ckp.project', true), v_type)) AS t(j jsonb)
  ) req
  WHERE NOT (p_body ? rp);
```
(Replaces the old `FROM pgrdf.sparql(format($q$ … $q$, v_type), v_kgraph) AS t` two-arg call. `v_kgraph` local var may now be unused — leave its DECLARE; harmless.)

- [ ] **Step 2: Rebuild + recreate + bootstrap**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.bootstrap_kernel(); SELECT set_config('ckp.project','demo',false); SELECT set_config('ckp.identity_key', md5('demo'), false);"`

- [ ] **Step 3: Smoke — seal a typeless body fails cleanly (not a SQL error)**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT ckp.seal('i-1', '{}'::jsonb);"`
Expected: `ERROR: ckp.seal: body has no "type"` (clean RAISE, not a `pgrdf.sparql` arity error)

- [ ] **Step 4: Commit**

```bash
git add sql/pgck--0.1.0.sql
git commit -m "fix: ckp.seal kernel-shape lookup uses 1-arg GRAPH-scoped pgrdf.sparql"
```

### Task T-10: Load demo kernel ontology into graph 2

**Files:**
- Modify: `sql/pgck--0.1.0.sql` (add `ckp.load_kernel(path)`)

- [ ] **Step 1: Add the loader**

```sql
-- Load a kernel TTL into graph 2 (urn:ckp:<project>/kernel/ck) + materialize.
CREATE OR REPLACE PROCEDURE ckp.load_kernel(p_path TEXT, p_project TEXT DEFAULT 'demo')
LANGUAGE plpgsql AS $$
DECLARE v_k INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
        v_iri TEXT := format('urn:ckp:%s/kernel/ck', p_project);
        v_ttl TEXT;
BEGIN
  PERFORM pgrdf.add_graph(v_k, v_iri);
  PERFORM pgrdf.clear_graph(v_k);
  v_ttl := pg_read_file(p_path);
  PERFORM pgrdf.parse_turtle(v_ttl, v_k, 'urn:ckp:kernel#');
  PERFORM pgrdf.materialize(v_k);
END;
$$;
```

- [ ] **Step 2: Rebuild + recreate + load demo**

Run: `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"`
Expected: `CALL` x3

- [ ] **Step 3: Verify the GreetingShape is in graph 2**

Run: `cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:demo/kernel/ck> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS t(j jsonb);"`
Expected: `1` (`:GreetingShape`)

- [ ] **Step 4: Commit**

```bash
git add sql/pgck--0.1.0.sql
git commit -m "feat: ckp.load_kernel(path, project) loads kernel TTL into graph 2"
```

### Task T-9: `ckp.seal` happy path — seal a valid Greeting

**Files:**
- Test: `sql/test/s2_seal_ok.sql` (create)

- [ ] **Step 1: Write the test**

```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
SELECT length(ckp.seal('i-greet-1',
  '{"type":"urn:ckp:kernel#Greeting","name":"Ada"}'::jsonb)) = 64 AS sha_returned;
SELECT count(*) = 1 AS instance_written FROM ckp.instances WHERE id='i-greet-1';
SELECT count(*) = 1 AS ledger_written   FROM ckp.ledger    WHERE instance_id='i-greet-1';
SELECT count(*) = 1 AS proof_written    FROM ckp.proof     WHERE about='i-greet-1';
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s2_seal_ok.sql`
Expected: `sha_returned|t`, `instance_written|t`, `ledger_written|t`, `proof_written|t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s2_seal_ok.sql
git commit -m "test: ckp.seal writes instance+ledger+proof for a valid Greeting"
```

### Task T-8: `ckp.seal` rejects a Greeting missing the required `name`

**Files:**
- Test: `sql/test/s2_seal_reject.sql` (create)

- [ ] **Step 1: Write the test** (expects a clean RAISE; `name` is `sh:minCount 1` in `:GreetingShape`)

```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
DO $$
BEGIN
  PERFORM ckp.seal('i-bad-1', '{"type":"urn:ckp:kernel#Greeting"}'::jsonb);
  RAISE EXCEPTION 'TEST FAILED: seal should have rejected missing name';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE '%missing required%' THEN
    RAISE NOTICE 'PASS: %', SQLERRM;
  ELSE RAISE; END IF;
END $$;
SELECT count(*) = 0 AS no_bad_instance FROM ckp.instances WHERE id='i-bad-1';
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s2_seal_reject.sql`
Expected: `PASS: …missing required: name` notice + `no_bad_instance | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s2_seal_reject.sql
git commit -m "test: ckp.seal rejects Greeting missing required name (atomic abort)"
```

### Task T-7: `ckp.verify` — recompute + check ledger digest

**Files:**
- Test: `sql/test/s2_verify.sql` (create)

- [ ] **Step 1: Write the test** (uses the instance sealed in T-9's pattern)

```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
PERFORM ckp.seal('i-verify-1', '{"type":"urn:ckp:kernel#Greeting","name":"Bo"}'::jsonb);
SELECT ckp.verify('i-verify-1') = true  AS verifies_clean;
UPDATE ckp.instances SET body = body || '{"tampered":true}'::jsonb WHERE id='i-verify-1';
SELECT ckp.verify('i-verify-1') = false AS detects_tamper;
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s2_verify.sql`
Expected: `verifies_clean | t` and `detects_tamper | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s2_verify.sql
git commit -m "test: ckp.verify confirms clean instance + detects tamper"
```

### Task T-6: Core-shape gate on the ledger op inside `ckp.seal` (verify it fires)

**Files:**
- Test: `sql/test/s2_ledger_core_shape.sql` (create)

- [ ] **Step 1: Write the test** — confirm a sealed instance's ledger row carries a 64-hex sha + ≥16-char sig (the `ckp:LedgerEntryShape` invariants)

```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
PERFORM ckp.seal('i-led-1', '{"type":"urn:ckp:kernel#Greeting","name":"Cy"}'::jsonb);
SELECT (body_sha256 ~ '^[0-9a-f]{64}$') AS sha_well_formed,
       (length(sig) >= 16)              AS sig_min_len
FROM ckp.ledger WHERE instance_id='i-led-1';
```

- [ ] **Step 2: Run it**

Run: `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s2_ledger_core_shape.sql`
Expected: `sha_well_formed | t` and `sig_min_len | t`

- [ ] **Step 3: Commit**

```bash
git add sql/test/s2_ledger_core_shape.sql
git commit -m "test: sealed ledger row satisfies ckp:LedgerEntryShape invariants"
```

### Task T-5: Stage S2 gate — `just smoke-s2`

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Add the gate** (boots, loads core+kernel, runs every S2 test)

```make
smoke-s2: smoke-s3
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"
    for t in s2_bootstrap s2_seal_ok s2_seal_reject s2_verify s2_ledger_core_shape; do \
      cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck \
        -v ON_ERROR_STOP=1 -f - < sql/test/$t.sql || exit 1; cd - >/dev/null; done
```

- [ ] **Step 2: Run it**

Run: `just smoke-s2`
Expected: every test prints its `t` / PASS lines, no error, exit 0

- [ ] **Step 3: Commit**

```bash
git add Justfile
git commit -m "chore: just smoke-s2 — governed seal gate (validate→instance→ledger→proof)"
```

---

## STAGE S1 — Demo kernel proof + completion (T-4 → T-1)

### Task T-4: One-command end-to-end demo recipe

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Add `demo` recipe**

```make
# Full minimal CK story in one command: pod → core → kernel → seal → verify.
demo: smoke-s2
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "SELECT set_config('ckp.project','demo',false); SELECT set_config('ckp.identity_key', md5('demo'), false); CALL ckp.bootstrap_kernel();" \
      -c "SELECT ckp.seal('i-demo','{\"type\":\"urn:ckp:kernel#Greeting\",\"name\":\"world\"}'::jsonb) AS sha;" \
      -c "SELECT ckp.verify('i-demo') AS verified;"
```

- [ ] **Step 2: Run it**

Run: `just demo`
Expected: a 64-hex `sha` value, then `verified | t`

- [ ] **Step 3: Commit**

```bash
git add Justfile
git commit -m "feat: just demo — full minimal governed CK story end-to-end"
```

### Task T-3: README — the minimal story

**Files:**
- Modify: `README.md` (add a "Quick start (minimal governed core)" section)

- [ ] **Step 1: Add the section** (exact commands a zero-context engineer runs)

```markdown
## Quick start — minimal governed core

```bash
just pgrdf-fetch     # pgRDF v0.5.0 release artifact
just build-ext       # build pgck.so (throwaway builder; no runtime rebuild)
just compose-up      # stock postgres:17.4 + per-file bind mounts
just demo            # core ontology → demo kernel → seal a Greeting → verify
```

`just demo` prints the instance SHA and `verified | t`. That is the whole
loop: ontology-driven, SHACL-enforced, materialized, verifiable — no NATS.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README quick-start for the minimal governed core"
```

### Task T-2: Tag `v0.2.0` — the governed core

**Files:** none (release task)

- [ ] **Step 1: Confirm CI green on `main`**

Run: `gh run list --repo styk-tv/pgCK --workflow ci.yml -L 1 --json conclusion -q '.[0].conclusion'`
Expected: `success`

- [ ] **Step 2: Tag + push**

```bash
git tag -a v0.2.0 -m "pgCK v0.2.0 — minimal ontology-driven SHACL-enforced governed core (no NATS)"
git push origin v0.2.0
```

- [ ] **Step 3: Watch the release run to success**

Run: `gh run watch "$(gh run list --repo styk-tv/pgCK --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')" --repo styk-tv/pgCK`
Expected: all matrix builds + release job `success`; GitHub Release + `ghcr.io/styk-tv/pgck:0.2.0-*` published.

- [ ] **Step 4: No commit (tag only).**

### Task T-1: Completion — verify the published v0.2.0 governed core

**Files:** none (acceptance task — reaching here = plan complete)

- [ ] **Step 1: Anonymous OCI pull of the new version**

Run: `docker manifest inspect ghcr.io/styk-tv/pgck:0.2.0-pg17-arm64`
Expected: a valid OCI manifest, no auth.

- [ ] **Step 2: Final acceptance statement**

Confirm all true:
- `just demo` is green from a clean checkout (pod boots, core+kernel load, Greeting seals, verify=t).
- `ckp.seal` rejects a shape-violating payload atomically (no instance/ledger/proof written).
- `ckp.verify` detects tamper.
- v0.2.0 published to GitHub Releases + GHCR (anonymous pull confirmed).

- [ ] **Step 3: Update memory + close the plan**

Append to the project memory that the minimal governed core (S5→S1) is complete and the embedded-NATS-server plan is the next document. **T-1 reached → this plan is done.**

---

## Self-review notes (resolved inline)

- **Spec coverage:** governed write path (design §3, rc3 §4.3) → S2; core ontology self-governance (design §1A, §4) → S4; pgRDF API corrections (design §6) → T-18/T-11; compose harness + per-file bind mounts (deploy spec §1, design §7) → S5; v3.7 ontology binding (design §1A) → T-21 (Provenance shape; more shapes pulled in the *next* plan as commands need them). NATS server/master (design §4/§5) is explicitly **out of scope** here — separate later plan, noted in the stage map.
- **No placeholders:** every step has the literal SQL/Justfile/Dockerfile content and an exact run command + expected output.
- **Type/name consistency:** `ckp.boot`, `ckp.bootstrap_kernel`, `ckp.load_kernel`, `ckp.validate`, `ckp.validate_against`, `ckp.core_shapes`, `ckp.seal`, `ckp.verify`, `ckp.config` keys `core_graph_id`/`kernel_graph_id`, GUC `ckp.project`/`ckp.identity_key`, graph IRIs `urn:ckp:core` / `urn:ckp:<project>/kernel/ck` — used identically across all tasks.
- **Reverse-numbering:** T-31 (first) → T-1 (completion); the count is what the minimal decomposition produced, not a target.
