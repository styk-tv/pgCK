# pgCK Minimal Event-Driven Governed Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow pgCK from green `v0.1.0` (`SELECT pgck_version()`) into the minimal **NATS/CKP event-driven** governed core: a topic conversation (`input.demo.Hello.create` → affordance → `ckp.seal` → `event.demo.Hello.created`) that is ontology-driven, SHACL-enforced, materialized, verified — built command-by-command.

**Architecture:** Execution is NATS/CKP-driven like FC.Thinker — tasks are *simple topic conversations*. pgCK **is** the NATS server (embedded in `pgck.so`); affordances declared in the kernel ontology materialise into live subscriptions; an inbound message is SPARQL-resolved to an affordance, its body SHACL-gated by `ckp:inShape`, sealed (instance+ledger+proof, atomic, core-shape-validated) and the result published proof-stamped to the affordance's `ckp:outTopic`. **Storage, SHACL, OWL reasoning, verification are entirely offloaded to pgRDF v0.5.0** — pgCK is the thin governance + dispatch orchestrator, nothing more.

**Build model (your directive):** *interleaved* — the smallest end-to-end vertical slice first (one topic → one affordance → one seal → one reply), then grow dispatch surface and governed ops *together*, command-by-command.

**Authority:** CKP v3.7 subject/affordance/envelope contract + FC.Thinker topic discipline. Resolution rule: **rc3 placement wins · v3.7 wins on semantics · FC.Thinker wins on proven topic-discipline shape.** This repo is where the v3.8 spec is proven; the website updates after.

**Tech Stack:** Rust + pgrx 0.16, PG17, pgRDF v0.5.0 (consumed from GitHub release), hand-rolled NATS Core server in `src/nats/` (feature `embedded-nats`, tokio), PL/pgSQL governed path, podman compose harness (cloned from pgRDF), `oras` OCI distribution.

**Method (mirrors pgRDF):** Stages **reverse-numbered**. Highest number done first; countdown to **T-1 = completion**. Each task = one tiny verifiable change + test + commit. Task count is the natural decomposition, not a target.

**Spec of record:** [`docs/specs/2026-05-16-pgck-core-design.md`](../specs/2026-05-16-pgck-core-design.md) §1A (CK spec binding, what pgCK is master of), `SPEC.PGCK.DEPLOY.v0.1.md`, `SPEC.CKP.3.8.MINIMAL-rc3.md`. Dispatch contract: the captured research report (FC.Thinker literal + v3.7) — subjects, envelope, promise algorithm, JetStream config, conflict resolutions D.1–D.5. v3.7 ontology: `conceptkernel.org/ontology/v3.7/` (local `/Users/neoxr/git_neux/xr-websockets-v4/ref-ck-org/docs/public/ontology/v3.7/`).

**Branch discipline (LOCKS v3.7.6):** all git writes on `pgck.task.PGCK-CORE`; `main` fast-forwarded after each green push. Never write `main`/`master` directly. After every task: `git push origin pgck.task.PGCK-CORE && git branch -f main pgck.task.PGCK-CORE && git push origin main`.

---

## Stage map (high → low; per-stage checkpoints with the user)

| Stage | Tasks | Outcome at the stage gate |
|---|---|---|
| **S5 — Pod harness** | T-34 … T-28 | pgRDF v0.5.0 + pgCK load in stock `postgres:17.4`; core+kernel ontology materialised; `ckp.seal` proven via psql (no NATS yet — the substrate the slice rides) |
| **S4 — pgRDF API fixes** | T-27 … T-22 | `ckp.validate` / `ckp.seal` use the real pgRDF v0.5.0 API (broken 2-arg `pgrdf.sparql` gone); seal+verify green vs the demo Greeting |
| **S3 — Embedded NATS Core server** | T-21 … T-14 | `src/nats/` server compiled into `pgck.so`; pub/sub/req-reply over `:4222`; a raw NATS round-trip works in the pod |
| **S2 — The vertical slice** | T-13 … T-5 | End-to-end: publish to `input.demo.Hello.create` → affordance SPARQL-resolved → `ckp.seal` → proof-stamped result on `event.demo.Hello.created` + `result.Hello`, demuxed by `trace_id` |
| **S1 — Grow + ship** | T-4 … T-1 | Affordance recompile on ontology change; reject path; `just demo` one-command story; **T-1 = v0.2.0 published, anon OCI pull confirmed = completion** |

Out of scope (separate later plan): JetStream durability beyond a single dedicated inbound stream, WSS listener for browsers, multi-kernel edges, `postgres_fdw`→Azure, ed25519 (HMAC stand-in stays).

---

## Conventions (every task)

- **Never build on macOS.** S5 builds the podman builder; thereafter `just build-ext` rebuilds only `pgck.so`, `podman compose restart postgres` reloads it (image never rebuilt). Local gate before any push: `cargo fmt --all -- --check` (exit 0). clippy/test run in CI.
- **pgRDF v0.5.0 API (authoritative — same surface as v0.4.6):**
  - `pgrdf.add_graph(id BIGINT, iri TEXT) → BIGINT`
  - `pgrdf.parse_turtle(content TEXT, graph_id BIGINT, base_iri TEXT DEFAULT NULL) → BIGINT`
  - `pgrdf.clear_graph(id BIGINT) → BIGINT`
  - `pgrdf.materialize(graph_id BIGINT, profile TEXT DEFAULT 'owl-rl') → JSONB`
  - `pgrdf.validate(data_graph_id BIGINT, shapes_graph_id BIGINT, mode TEXT DEFAULT 'native') → JSONB` (top-level bool key `conforms`)
  - `pgrdf.sparql(q TEXT) → SETOF JSONB` — **ONE arg.** Graph-scope via SPARQL `GRAPH <iri> { … }`. Rows flat JSONB by bare var; read `... FROM pgrdf.sparql(q) AS j` then `j->>'var'`.
- **Subjects (resolution D.1/D.3):** inbound `input.demo.Hello.create` (its own dedicated JetStream stream — never co-stream event./result.); reply to the affordance `ckp:outTopic` `event.demo.Hello.created` AND mirror `result.Hello`.
- **Correlation (D.2):** `Trace-Id: tx-{uuid}` header, echoed as body `trace_id`. No separate `i`.
- **Envelope (D.4):** request `{ "action": "create", "data": {…} }`; result `{ action, data, trace_id, kernel, timestamp }`.
- **Commit prefixes:** `feat:` ability, `fix:` defect, `test:` test-only, `chore:` harness.

---

## STAGE S5 — Pod harness + seal substrate (T-34 → T-28)

### Task T-34: `just pgrdf-fetch` — download+verify pgRDF v0.5.0

**Files:** Create `Justfile` (replace hydrated stub); Modify `.gitignore`

- [ ] **Step 1: Write recipe**

```make
set shell := ["bash", "-uc"]
pgrdf_ver := "0.5.0"
pg := "17"
arch := "arm64"

pgrdf-fetch:
    mkdir -p compose/extensions/pgrdf
    cd compose/extensions/pgrdf && \
      gh release download "v{{pgrdf_ver}}" --repo styk-tv/pgRDF \
        --pattern "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" \
        --pattern "SHA256SUMS" --clobber && \
      grep "pg{{pg}}-glibc-{{arch}}" SHA256SUMS | sha256sum -c - && \
      tar xzf "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" --strip-components=1
```

- [ ] **Step 2: Run** `just pgrdf-fetch` — Expected: `sha256sum -c` prints `OK`; `compose/extensions/pgrdf/lib/pgrdf.so` exists.
- [ ] **Step 3: Verify** `file compose/extensions/pgrdf/lib/pgrdf.so` — Expected: `ELF 64-bit LSB shared object, ARM aarch64`.
- [ ] **Step 4:** Add to `.gitignore`:
```
/compose/extensions/pgrdf/
/compose/extensions/pgck/
/compose/pg-data/
```
- [ ] **Step 5: Commit**
```bash
git add Justfile .gitignore
git commit -m "chore: just pgrdf-fetch — download+verify pgRDF v0.5.0 release"
```

### Task T-33: Builder Containerfile (clone of pgRDF's)

**Files:** Create `compose/builder.Containerfile`

- [ ] **Step 1: Write it**
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

### Task T-32: `just build-ext` + `compose-up`/`down`/`psql`

**Files:** Modify `Justfile`

- [ ] **Step 1: Append**
```make
build := env_var_or_default("PGCK_BUILD_RUNTIME", "podman")
run   := env_var_or_default("PGCK_RUN_RUNTIME", "podman")

build-ext:
    DOCKER_BUILDKIT=1 {{build}} build --target export \
      -t pgck-builder:pg{{pg}} --build-arg PG_MAJOR={{pg}} \
      -f compose/builder.Containerfile .
    rm -rf compose/extensions/pgck/lib compose/extensions/pgck/share
    mkdir -p compose/extensions/pgck
    {{build}} run --rm -v "$PWD/compose/extensions/pgck:/export" pgck-builder:pg{{pg}}

compose-up:
    cd compose && {{run}} compose up -d
compose-down:
    cd compose && {{run}} compose down
psql:
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck
```
- [ ] **Step 2: Run** `just build-ext` — Expected: `compose/extensions/pgck/lib/pgck.so` exists.
- [ ] **Step 3: Verify** `file compose/extensions/pgck/lib/pgck.so` — Expected: `ELF 64-bit LSB shared object, ARM aarch64`.
- [ ] **Step 4: Commit**
```bash
git add Justfile
git commit -m "chore: just build-ext/compose-up/down/psql"
```

### Task T-31: compose.yml — the pod (per-file bind mounts)

**Files:** Create `compose/compose.yml`

- [ ] **Step 1: Write it** (NEVER a dir mount over `$sharedir/extension`)
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
    ports: ["${POSTGRES_PORT:-5432}:5432", "${NATS_PORT:-4222}:4222"]
    volumes:
      - ./pg-data:/var/lib/postgresql/data:z
      - ./extensions/pgrdf/lib/pgrdf.so:/usr/lib/postgresql/17/lib/pgrdf.so:ro,z
      - ./extensions/pgrdf/share/extension/pgrdf.control:/usr/share/postgresql/17/extension/pgrdf.control:ro,z
      - ./extensions/pgrdf/share/extension/pgrdf--0.5.0.sql:/usr/share/postgresql/17/extension/pgrdf--0.5.0.sql:ro,z
      - ./extensions/pgck/lib/pgck.so:/usr/lib/postgresql/17/lib/pgck.so:ro,z
      - ./extensions/pgck/share/extension/pgck.control:/usr/share/postgresql/17/extension/pgck.control:ro,z
      - ./extensions/pgck/share/extension/pgck--0.1.1.sql:/usr/share/postgresql/17/extension/pgck--0.1.1.sql:ro,z
      - ../ontology:/ontology:ro,z
      - ../examples:/examples:ro,z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-pgck} -d ${POSTGRES_DB:-pgck}"]
      interval: 10s
      timeout: 5s
      retries: 5
```
- [ ] **Step 2: Commit**
```bash
git add compose/compose.yml
git commit -m "chore: compose.yml — stock postgres:17.4, per-file bind mounts, :4222 exposed"
```

### Task T-30: Boot pod; create both extensions (re-add `requires='pgrdf'`)

**Files:** Modify `pgck.control`

- [ ] **Step 1:** In `pgck.control`, replace the `# NOTE: … requires … omitted …` comment block with:
```
# pgRDF must be installed in the same DB (compose bind-mounts it).
requires = 'pgrdf'
```
- [ ] **Step 2: Bring up**
```bash
just pgrdf-fetch && just build-ext && just compose-up
```
Then: `until cd compose && podman compose exec postgres pg_isready -U pgck; do sleep 2; done`
- [ ] **Step 3: Create both**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -c "CREATE EXTENSION pgrdf; CREATE EXTENSION pgck;"
```
Expected: two `CREATE EXTENSION` lines.
- [ ] **Step 4: Verify**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT pgrdf.version(); SELECT pgck_version();"
```
Expected: a `0.5.0` string then `pgck 0.1.0 (rc3)`.
- [ ] **Step 5: Commit**
```bash
git add pgck.control
git commit -m "feat: re-add requires='pgrdf'; both extensions load in compose pod"
```

### Task T-29: `ckp.boot()` + `ckp.load_kernel()` — load core+kernel ontology

**Files:** Modify `sql/pgck--0.1.1.sql`

- [ ] **Step 1: Add both procedures** (after `ckp.bootstrap_kernel`)
```sql
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
- [ ] **Step 2: Rebuild + recreate + load**
```bash
just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"
```
Expected: `CALL` ×4 (boot, load_kernel, plus the two CREATE/DROP).
- [ ] **Step 3: Verify graphs populated**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS j; SELECT count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:demo/kernel/ck> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }') AS j;"
```
Expected: `4` (core shapes) then `1` (`:GreetingShape`).
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql
git commit -m "feat: ckp.boot()+ckp.load_kernel() load core+kernel ontology into pgRDF"
```

### Task T-28: Stage S5 gate — `just smoke-s5`

**Files:** Modify `Justfile`

- [ ] **Step 1: Add gate**
```make
smoke-s5: pgrdf-fetch build-ext compose-up
    until cd compose && {{run}} compose exec postgres pg_isready -U pgck; do sleep 2; done
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "CREATE EXTENSION IF NOT EXISTS pgrdf; DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck;" \
      -c "CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');" \
      -tc "SELECT pgck_version();"
```
- [ ] **Step 2: Run** `just smoke-s5` — Expected: final line `pgck 0.1.0 (rc3)`, no error.
- [ ] **Step 3: Commit**
```bash
git add Justfile
git commit -m "chore: just smoke-s5 — pod + both extensions + ontology loaded"
```

**→ CHECKPOINT: report S5 to user.**

---

## STAGE S4 — pgRDF API fixes + governed seal (T-27 → T-22)

### Task T-27: Fix `ckp.validate` — real pgRDF API

**Files:** Modify `sql/pgck--0.1.1.sql`

- [ ] **Step 1: Replace the function body**
```sql
CREATE OR REPLACE FUNCTION ckp.validate(ttl TEXT, shapes_graph_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE scratch_id INT := 9000 + (random()*900)::int; report JSONB;
BEGIN
  PERFORM pgrdf.add_graph(scratch_id, format('urn:ckp:scratch:%s', scratch_id));
  PERFORM pgrdf.clear_graph(scratch_id);
  PERFORM pgrdf.parse_turtle(ttl, scratch_id, 'urn:ckp:scratch#');
  report := pgrdf.validate(scratch_id, shapes_graph_id);
  PERFORM pgrdf.clear_graph(scratch_id);
  RETURN COALESCE((report->>'conforms')::boolean, false);
END;
$$;
```
- [ ] **Step 2: Rebuild+recreate** (`just build-ext` + restart + DROP/CREATE pgck + `CALL ckp.boot()`).
- [ ] **Step 3: Smoke**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT ckp.validate('@prefix x: <urn:x#> . x:a x:b 1 .', 1);"
```
Expected: `t`.
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql
git commit -m "fix: ckp.validate uses real pgRDF v0.5.0 API (2-arg validate, no broken sparql)"
```

### Task T-26: `ckp.validate` rejects bad / accepts good Proof

**Files:** Create `sql/test/s4_validate.sql`

- [ ] **Step 1: Write test**
```sql
\set ON_ERROR_STOP 1
SELECT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
  <urn:ckp:prf:bad> a ckp:Proof ; ckp:about <urn:ckp:i:1> .', 1) = false AS rejects_bad;
SELECT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  <urn:ckp:prf:ok> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "ed25519+sha256" ;
  ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
  ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) = true AS accepts_good;
```
- [ ] **Step 2: Run** `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s4_validate.sql` — Expected: `rejects_bad | t`, `accepts_good | t`.
- [ ] **Step 3: Commit**
```bash
git add sql/test/s4_validate.sql
git commit -m "test: ckp.validate rejects malformed / accepts well-formed ckp:Proof"
```

### Task T-25: Fix `ckp.seal` kernel-shape lookup — 1-arg GRAPH-scoped sparql

**Files:** Modify `sql/pgck--0.1.1.sql` (the `ckp.seal` required-prop block)

- [ ] **Step 1: Replace the broken 2-arg sparql block**
```sql
  SELECT string_agg(rp, ', ') INTO v_missing
  FROM (
    SELECT j->>'required_prop' AS rp
    FROM pgrdf.sparql(format($q$
      PREFIX sh: <http://www.w3.org/ns/shacl#>
      SELECT ?required_prop WHERE {
        GRAPH <urn:ckp:%s/kernel/ck> {
          ?s sh:targetClass <%s> ; sh:property ?p .
          ?p sh:path ?required_prop ; sh:minCount ?n . FILTER(?n >= 1) } }
    $q$, current_setting('ckp.project', true), v_type)) AS j
  ) req
  WHERE NOT (p_body ? rp);
```
- [ ] **Step 2: Rebuild+recreate**; then `SELECT set_config('ckp.project','demo',false); SELECT set_config('ckp.identity_key',md5('demo'),false); CALL ckp.bootstrap_kernel();`
- [ ] **Step 3: Smoke** (clean RAISE, not arity error)
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc "SELECT ckp.seal('i-1','{}'::jsonb);"
```
Expected: `ERROR: ckp.seal: body has no "type"`.
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql
git commit -m "fix: ckp.seal kernel-shape lookup uses 1-arg GRAPH-scoped pgrdf.sparql"
```

### Task T-25b: Declare pgcrypto dependency (inserted — surfaced during T-25)

**Files:** Modify `pgck.control`

`ckp.seal` uses `digest()` + `hmac()` and `ckp.verify` uses `digest()` — all from
**pgcrypto** — but `pgck.control` only declared `requires = 'pgrdf'`. No seal/verify
can complete until pgcrypto is installed. pgcrypto is stock contrib in
`postgres:17.4-bookworm`; declaring it in `requires` makes `CREATE EXTENSION pgck`
auto-create it.

- [ ] **Step 1:** In `pgck.control`, change `requires = 'pgrdf'` to:
```
requires = 'pgrdf, pgcrypto'
```
(keep the `# pgRDF must be installed …` comment line above it; add `, pgcrypto` only).

- [ ] **Step 2: Rebuild + recreate + verify auto-create:**
```bash
cd /Users/neoxr/git_conceptkernel/pgCK && just build-ext && just compose-recreate && cd compose && (until podman compose exec postgres pg_isready -U pgck >/dev/null 2>&1; do sleep 2; done) && podman compose exec postgres psql -U pgck -d pgck -c "CREATE EXTENSION IF NOT EXISTS pgrdf; DROP EXTENSION IF EXISTS pgck CASCADE; CREATE EXTENSION pgck;" -tc "SELECT extname FROM pg_extension WHERE extname IN ('pgrdf','pgck','pgcrypto') ORDER BY extname;"
```
Expected: three rows — `pgck`, `pgcrypto`, `pgrdf` (pgcrypto auto-created by the requires).

- [ ] **Step 3: Smoke a full seal returns a 64-hex sha:**
```bash
cd /Users/neoxr/git_conceptkernel/pgCK/compose && podman compose exec postgres psql -U pgck -d pgck -tc "CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo'); SELECT set_config('ckp.project','demo',false); SELECT set_config('ckp.identity_key',md5('demo'),false); CALL ckp.bootstrap_kernel(); SELECT length(ckp.seal('i-25b','{\"type\":\"urn:ckp:kernel#Greeting\",\"name\":\"Ada\"}'::jsonb));"
```
Expected: `64`.

- [ ] **Step 4: Commit:**
```bash
cd /Users/neoxr/git_conceptkernel/pgCK
git add pgck.control
git commit -m "fix: declare pgcrypto dependency (ckp.seal/verify use digest+hmac)"
```

### Task T-24: `ckp.seal` happy path — seal a valid Greeting

**Files:** Create `sql/test/s4_seal_ok.sql`

- [ ] **Step 1: Write test**
```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
SELECT length(ckp.seal('i-greet-1','{"type":"urn:ckp:kernel#Greeting","name":"Ada"}'::jsonb))=64 AS sha_ok;
SELECT count(*)=1 AS inst FROM ckp.instances WHERE id='i-greet-1';
SELECT count(*)=1 AS led  FROM ckp.ledger    WHERE instance_id='i-greet-1';
SELECT count(*)=1 AS prf  FROM ckp.proof     WHERE about='i-greet-1';
```
- [ ] **Step 2: Run** `cd compose && podman compose exec -T postgres psql -U pgck -d pgck -f - < sql/test/s4_seal_ok.sql` — Expected: four `t`.
- [ ] **Step 3: Commit**
```bash
git add sql/test/s4_seal_ok.sql
git commit -m "test: ckp.seal writes instance+ledger+proof for a valid Greeting"
```

### Task T-23: `ckp.seal` rejects + `ckp.verify` detects tamper

**Files:** Create `sql/test/s4_seal_reject.sql`, `sql/test/s4_verify.sql`

- [ ] **Step 1: Write reject test**
```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
DO $$ BEGIN
  PERFORM ckp.seal('i-bad-1','{"type":"urn:ckp:kernel#Greeting"}'::jsonb);
  RAISE EXCEPTION 'TEST FAILED: should reject missing name';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE '%missing required%' THEN RAISE NOTICE 'PASS: %', SQLERRM;
  ELSE RAISE; END IF; END $$;
SELECT count(*)=0 AS no_bad FROM ckp.instances WHERE id='i-bad-1';
```
- [ ] **Step 2: Write verify test**
```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
SELECT ckp.seal('i-v-1','{"type":"urn:ckp:kernel#Greeting","name":"Bo"}'::jsonb) IS NOT NULL AS sealed;
SELECT ckp.verify('i-v-1')=true AS clean;
UPDATE ckp.instances SET body=body||'{"x":1}'::jsonb WHERE id='i-v-1';
SELECT ckp.verify('i-v-1')=false AS tampered;
```
- [ ] **Step 3: Run both** — Expected: `PASS: …missing required: name`, `no_bad|t`; then `sealed|t`, `clean|t`, `tampered|t`.
- [ ] **Step 4: Commit**
```bash
git add sql/test/s4_seal_reject.sql sql/test/s4_verify.sql
git commit -m "test: ckp.seal atomic-rejects bad Greeting; ckp.verify detects tamper"
```

### Task T-22: Stage S4 gate — `just smoke-s4`

**Files:** Modify `Justfile`

- [ ] **Step 1: Add gate**
```make
smoke-s4: smoke-s5
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"
    for t in s4_validate s4_seal_ok s4_seal_reject s4_verify; do \
      cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck \
        -v ON_ERROR_STOP=1 -f - < sql/test/$t.sql || exit 1; cd - >/dev/null; done
```
- [ ] **Step 2: Run** `just smoke-s4` — Expected: all tests pass, exit 0.
- [ ] **Step 3: Commit**
```bash
git add Justfile
git commit -m "chore: just smoke-s4 — governed seal proven via psql (slice substrate)"
```

**→ CHECKPOINT: report S4 to user.**

---

## STAGE S3 — Embedded NATS Core server (T-21 → T-14)

### Task T-21: Cargo wiring — `embedded-nats` feature on by default for dev

**Files:** Modify `Cargo.toml`

- [ ] **Step 1:** Change `default = []` → `default = ["embedded-nats"]` and confirm the `embedded-nats = ["dep:tokio"]` + `tokio = { …, optional = true }` lines exist (added in the init phase). Verify `async-nats = "0.48"` present.
- [ ] **Step 2: fmt** `cargo fmt --all -- --check` — exit 0.
- [ ] **Step 3: Commit**
```bash
git add Cargo.toml
git commit -m "chore: default feature embedded-nats (dev builds the in-.so NATS server)"
```

### Task T-20: `src/nats/parser.rs` — NATS Core verb parser

**Files:** Create `src/nats/mod.rs`, `src/nats/parser.rs`; Modify `src/lib.rs`

- [ ] **Step 1: `src/nats/mod.rs`**
```rust
//! Embedded NATS Core server (hand-rolled). v3.7 + FC.Thinker discipline.
pub mod parser;
```
- [ ] **Step 2: `src/nats/parser.rs`** — parse the client→server verbs (CRLF-framed)
```rust
//! NATS Core client→server verb parser. Subset: CONNECT, PING, PONG,
//! PUB, SUB, UNSUB. (INFO/MSG/+OK/-ERR are server→client; see server.rs.)
#[derive(Debug, PartialEq)]
pub enum ClientMsg {
    Connect(String),
    Ping,
    Pong,
    Sub { subject: String, queue: Option<String>, sid: String },
    Unsub { sid: String, max: Option<u64> },
    Pub { subject: String, reply: Option<String>, payload: Vec<u8> },
}

/// Parse one control line (no payload yet). Returns None if incomplete/unknown.
pub fn parse_line(line: &str) -> Option<ClientMsg> {
    let mut it = line.split_whitespace();
    match it.next()?.to_ascii_uppercase().as_str() {
        "PING" => Some(ClientMsg::Ping),
        "PONG" => Some(ClientMsg::Pong),
        "CONNECT" => Some(ClientMsg::Connect(line[7..].trim().to_string())),
        "SUB" => {
            let subject = it.next()?.to_string();
            let a = it.next()?;
            let b = it.next();
            match b {
                Some(sid) => Some(ClientMsg::Sub { subject, queue: Some(a.to_string()), sid: sid.to_string() }),
                None => Some(ClientMsg::Sub { subject, queue: None, sid: a.to_string() }),
            }
        }
        "UNSUB" => {
            let sid = it.next()?.to_string();
            let max = it.next().and_then(|s| s.parse().ok());
            Some(ClientMsg::Unsub { sid, max })
        }
        "PUB" => {
            let subject = it.next()?.to_string();
            let parts: Vec<&str> = it.collect();
            // PUB <subj> [reply] <#bytes> — payload read separately by caller.
            let (reply, _n) = if parts.len() == 2 {
                (Some(parts[0].to_string()), parts[1])
            } else { (None, parts[0]) };
            Some(ClientMsg::Pub { subject, reply, payload: Vec::new() })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn ping() { assert_eq!(parse_line("PING"), Some(ClientMsg::Ping)); }
    #[test] fn sub_no_queue() {
        assert_eq!(parse_line("SUB input.demo.Hello.create 1"),
            Some(ClientMsg::Sub{subject:"input.demo.Hello.create".into(),queue:None,sid:"1".into()}));
    }
    #[test] fn pub_with_reply() {
        assert_eq!(parse_line("PUB a.b _INBOX.1 5"),
            Some(ClientMsg::Pub{subject:"a.b".into(),reply:Some("_INBOX.1".into()),payload:vec![]}));
    }
}
```
- [ ] **Step 3:** In `src/lib.rs` add near the other `mod`s: `#[cfg(feature = "embedded-nats")] mod nats;`
- [ ] **Step 4: fmt + unit test locally** `cargo fmt --all -- --check && cargo test --no-default-features --features embedded-nats parser 2>&1 | tail -3`
Expected: fmt exit 0; 3 parser tests pass (pure Rust — no PG needed).
- [ ] **Step 5: Commit**
```bash
git add src/nats/mod.rs src/nats/parser.rs src/lib.rs
git commit -m "feat: src/nats/parser.rs — NATS Core client-verb parser + unit tests"
```

### Task T-19: `src/nats/router.rs` — subject match + subscription table

**Files:** Create `src/nats/router.rs`; Modify `src/nats/mod.rs`

- [ ] **Step 1: `src/nats/router.rs`** — token wildcard match (`*`, `>`) + sub registry
```rust
//! Subject routing: literal + `*` (one token) + `>` (trailing) match,
//! and a subscription table (sid -> subject pattern).
use std::collections::HashMap;

pub fn matches(pattern: &str, subject: &str) -> bool {
    let mut p = pattern.split('.');
    let mut s = subject.split('.');
    loop {
        match (p.next(), s.next()) {
            (Some(">"), Some(_)) => return true,
            (Some("*"), Some(_)) => continue,
            (Some(a), Some(b)) if a == b => continue,
            (None, None) => return true,
            _ => return false,
        }
    }
}

#[derive(Default)]
pub struct Router { subs: HashMap<String, String> } // sid -> pattern

impl Router {
    pub fn add(&mut self, sid: &str, pattern: &str) { self.subs.insert(sid.into(), pattern.into()); }
    pub fn remove(&mut self, sid: &str) { self.subs.remove(sid); }
    /// sids whose pattern matches `subject`.
    pub fn match_sids(&self, subject: &str) -> Vec<String> {
        self.subs.iter().filter(|(_, p)| matches(p, subject)).map(|(k, _)| k.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn literal() { assert!(matches("a.b.c", "a.b.c")); assert!(!matches("a.b", "a.b.c")); }
    #[test] fn star() { assert!(matches("a.*.c", "a.x.c")); assert!(!matches("a.*.c", "a.x.y")); }
    #[test] fn gt() { assert!(matches("event.demo.Hello.>", "event.demo.Hello.created")); }
    #[test] fn route() {
        let mut r = Router::default();
        r.add("1", "input.demo.Hello.create");
        assert_eq!(r.match_sids("input.demo.Hello.create"), vec!["1".to_string()]);
        assert!(r.match_sids("other").is_empty());
    }
}
```
- [ ] **Step 2:** Add `pub mod router;` to `src/nats/mod.rs`.
- [ ] **Step 3: fmt + test** `cargo fmt --all -- --check && cargo test --no-default-features --features embedded-nats router 2>&1 | tail -3` — Expected: fmt 0; 4 tests pass.
- [ ] **Step 4: Commit**
```bash
git add src/nats/router.rs src/nats/mod.rs
git commit -m "feat: src/nats/router.rs — wildcard subject match + sub table + tests"
```

### Task T-18: `src/nats/server.rs` — tokio accept loop (skeleton, no SPI)

**Files:** Create `src/nats/server.rs`; Modify `src/nats/mod.rs`

- [ ] **Step 1: `src/nats/server.rs`** — accept connections, INFO/PING/PONG, hold subs in the Router; deliver MSG to matching subscribers. No SPI here.
```rust
//! Minimal NATS Core server: TcpListener accept loop on :4222.
//! Handles INFO/CONNECT/PING/PONG/SUB/UNSUB/PUB and MSG fan-out.
//! No SPI — the bgworker bridges sealed work (see bgworker.rs).
use crate::nats::parser::{parse_line, ClientMsg};
use crate::nats::router::Router;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

const INFO: &str = "INFO {\"server_name\":\"pgck\",\"version\":\"0.1.0\",\"max_payload\":1048576}\r\n";

#[derive(Clone)]
struct Delivery { subject: String, reply: Option<String>, payload: Vec<u8> }

pub async fn run(bind: &str) -> std::io::Result<()> {
    let listener = TcpListener::bind(bind).await?;
    let (tx, _) = broadcast::channel::<Delivery>(1024);
    let router = Arc::new(Mutex::new(Router::default()));
    loop {
        let (sock, _) = listener.accept().await?;
        let tx = tx.clone();
        let mut rx = tx.subscribe();
        let router = router.clone();
        tokio::spawn(async move {
            let (rd, mut wr) = sock.into_split();
            let mut lines = BufReader::new(rd).lines();
            if wr.write_all(INFO.as_bytes()).await.is_err() { return; }
            loop {
                tokio::select! {
                    line = lines.next_line() => {
                        let Ok(Some(l)) = line else { break; };
                        match parse_line(&l) {
                            Some(ClientMsg::Ping) => { let _ = wr.write_all(b"PONG\r\n").await; }
                            Some(ClientMsg::Sub{subject,sid,..}) => router.lock().unwrap().add(&sid,&subject),
                            Some(ClientMsg::Unsub{sid,..}) => router.lock().unwrap().remove(&sid),
                            Some(ClientMsg::Pub{subject,reply,..}) => {
                                let _ = tx.send(Delivery{subject,reply,payload:Vec::new()});
                            }
                            _ => {}
                        }
                    }
                    d = rx.recv() => {
                        let Ok(d) = d else { continue; };
                        let sids = router.lock().unwrap().match_sids(&d.subject);
                        for sid in sids {
                            let hdr = format!("MSG {} {} {}\r\n\r\n", d.subject, sid, d.payload.len());
                            if wr.write_all(hdr.as_bytes()).await.is_err() { return; }
                        }
                    }
                }
            }
        });
    }
}
```
- [ ] **Step 2:** Add `pub mod server;` to `src/nats/mod.rs`.
- [ ] **Step 3: fmt + compile-check** `cargo fmt --all -- --check && cargo build --no-default-features --features embedded-nats 2>&1 | tail -3`
Expected: fmt 0; build succeeds (no clippy gate here — CI runs it).
- [ ] **Step 4: Commit**
```bash
git add src/nats/server.rs src/nats/mod.rs
git commit -m "feat: src/nats/server.rs — minimal NATS Core accept loop + MSG fanout"
```

### Task T-17: `bgworker.rs` hosts the server on a dedicated thread

**Files:** Modify `src/bgworker.rs`, `src/lib.rs`

- [ ] **Step 1: `src/bgworker.rs`** — spawn the tokio server once (OnceLock-guarded), off the SPI thread
```rust
//! Server host. Owns the embedded NATS server lifecycle on a dedicated
//! thread (never touches SPI). The SPI bridge (seal drain) lands in S2.
#[cfg(feature = "embedded-nats")]
use std::sync::OnceLock;

#[cfg(feature = "embedded-nats")]
static SERVER: OnceLock<()> = OnceLock::new();

/// One scheduler tick. Idempotently starts the NATS server thread.
pub fn tick() {
    #[cfg(feature = "embedded-nats")]
    SERVER.get_or_init(|| {
        std::thread::spawn(|| {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all().build().expect("tokio rt");
            rt.block_on(async {
                if let Err(e) = crate::nats::server::run("0.0.0.0:4222").await {
                    pgrx::log!("pgck: nats server exited: {e}");
                }
            });
        });
    });
}
```
- [ ] **Step 2: fmt + build** `cargo fmt --all -- --check && cargo build --no-default-features --features embedded-nats 2>&1 | tail -3` — Expected: fmt 0; build ok.
- [ ] **Step 3: Commit**
```bash
git add src/bgworker.rs
git commit -m "feat: bgworker hosts the embedded NATS server on a dedicated thread"
```

### Task T-16: Rebuild pod; verify the server listens

**Files:** none (verification)

- [ ] **Step 1: Rebuild+bounce** `just build-ext && cd compose && podman compose restart postgres && until podman compose exec postgres pg_isready -U pgck; do sleep 2; done && podman compose exec postgres psql -U pgck -d pgck -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck;"`
- [ ] **Step 2: Probe :4222 for the INFO banner from the host**
```bash
printf 'PING\r\n' | nc -w2 127.0.0.1 4222 | head -c 200
```
Expected: an `INFO {…"server_name":"pgck"…}` line followed by `PONG`.
- [ ] **Step 3: Record outcome in T-15's commit (no commit here).**

### Task T-15: Raw NATS round-trip test (nats CLI)

**Files:** Create `sql/test/s3_nats_roundtrip.sh`

- [ ] **Step 1: Write the harness** (uses the `nats` CLI already on PATH, v2.x)
```bash
#!/usr/bin/env bash
set -euo pipefail
# Sub in background, pub, expect delivery. pgCK NATS server on :4222.
nats --server nats://127.0.0.1:4222 sub 'event.demo.Hello.>' --count=1 > /tmp/pgck_rt.out 2>&1 &
SUB=$!
sleep 1
nats --server nats://127.0.0.1:4222 pub 'event.demo.Hello.created' '{"trace_id":"tx-test","data":{"status":"created"}}'
wait $SUB
grep -q 'tx-test' /tmp/pgck_rt.out && echo "ROUNDTRIP OK" || { echo "ROUNDTRIP FAIL"; cat /tmp/pgck_rt.out; exit 1; }
```
- [ ] **Step 2: Run** `bash sql/test/s3_nats_roundtrip.sh` — Expected: `ROUNDTRIP OK`.
- [ ] **Step 3: Commit**
```bash
git add sql/test/s3_nats_roundtrip.sh
git commit -m "test: raw NATS pub/sub round-trip against embedded pgck server"
```

### Task T-14: Stage S3 gate — `just smoke-s3`

**Files:** Modify `Justfile`

- [ ] **Step 1: Add gate**
```make
smoke-s3: smoke-s4
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck;"
    sleep 3
    printf 'PING\r\n' | nc -w2 127.0.0.1 4222 | grep -q server_name && echo "INFO banner OK"
    bash sql/test/s3_nats_roundtrip.sh
```
- [ ] **Step 2: Run** `just smoke-s3` — Expected: `INFO banner OK`, `ROUNDTRIP OK`.
- [ ] **Step 3: Commit**
```bash
git add Justfile
git commit -m "chore: just smoke-s3 — embedded NATS server gate"
```

**→ CHECKPOINT: report S3 to user.**

---

## STAGE S2 — The vertical slice (T-13 → T-5)

### Task T-13: `ckp.affordances()` — SPARQL-resolve affordance rows

**Files:** Modify `sql/pgck--0.1.1.sql`; Create `sql/test/s2_affordances.sql`

- [ ] **Step 1: Add the resolver**
```sql
-- Enumerate affordances from the kernel CK graph: inTopic, outTopic, inShape.
CREATE OR REPLACE FUNCTION ckp.affordances(p_project TEXT DEFAULT 'demo')
RETURNS TABLE(in_topic TEXT, out_topic TEXT, in_shape TEXT)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT j->>'it', j->>'ot', j->>'sh'
  FROM pgrdf.sparql(format($q$
    PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
    SELECT ?it ?ot ?sh WHERE {
      GRAPH <urn:ckp:%s/kernel/ck> {
        ?a a ckp:Affordance ; ckp:inTopic ?it .
        OPTIONAL { ?a ckp:outTopic ?ot } OPTIONAL { ?a ckp:inShape ?sh } } }
  $q$, p_project)) AS j;
END;
$$;
```
- [ ] **Step 2: Test** `sql/test/s2_affordances.sql`
```sql
\set ON_ERROR_STOP 1
SELECT in_topic='input.demo.Hello.create' AS topic_ok,
       out_topic='event.demo.Hello.created' AS out_ok
FROM ckp.affordances('demo');
```
- [ ] **Step 3: Rebuild+recreate+load; run** — Expected: `topic_ok|t`, `out_ok|t`.
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql sql/test/s2_affordances.sql
git commit -m "feat: ckp.affordances() SPARQL-resolves inTopic/outTopic/inShape"
```

### Task T-12: `ckp.dispatch(subject, body_json)` — the 8-step cycle, in SQL

**Files:** Modify `sql/pgck--0.1.1.sql`

- [ ] **Step 1: Add dispatch** (steps 4–7 of the v3.7 cycle; authn/authz upstream/seal-time per design §1A)
```sql
-- Resolve subject -> affordance, seal data, return the proof-stamped result
-- envelope. trace_id is the correlation id (v3.7). Caller (bgworker) does
-- the NATS publish to out_topic + result.<kernel>.
CREATE OR REPLACE FUNCTION ckp.dispatch(p_subject TEXT, p_msg JSONB,
                                         p_project TEXT DEFAULT 'demo')
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_out TEXT; v_shape TEXT; v_trace TEXT; v_action TEXT;
        v_data JSONB; v_id TEXT; v_kernel TEXT := split_part(p_subject,'.',3);
BEGIN
  SELECT out_topic, in_shape INTO v_out, v_shape
  FROM ckp.affordances(p_project) WHERE in_topic = p_subject;
  IF v_out IS NULL THEN
    RETURN jsonb_build_object('error', format('no affordance for %s', p_subject));
  END IF;
  v_trace  := COALESCE(p_msg->>'trace_id', 'tx-'||gen_random_uuid());
  v_action := p_msg->>'action';
  v_data   := p_msg->'data';
  v_id     := format('i-%s-%s', v_trace, floor(extract(epoch from now()))::bigint);
  PERFORM ckp.seal(v_id, jsonb_set(v_data, '{type}', '"urn:ckp:kernel#Greeting"'));
  RETURN jsonb_build_object(
    'action', v_action,
    'data', jsonb_build_object('instance_id', v_id, 'status', 'created'),
    'trace_id', v_trace, 'kernel', v_kernel,
    'timestamp', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'out_topic', v_out);
END;
$$;
```
- [ ] **Step 2: Rebuild+recreate+load**; set `ckp.project`/`ckp.identity_key`; `CALL ckp.bootstrap_kernel();`
- [ ] **Step 3: Smoke**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc \
 "SELECT ckp.dispatch('input.demo.Hello.create','{\"action\":\"create\",\"trace_id\":\"tx-1\",\"data\":{\"name\":\"Ada\"}}'::jsonb)->>'status';"
```
Expected: `created`.
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql
git commit -m "feat: ckp.dispatch() — subject->affordance->seal->result envelope"
```

### Task T-11: `ckp.dispatch` reject path (shape violation → error envelope, no write)

**Files:** Create `sql/test/s2_dispatch_reject.sql`

- [ ] **Step 1: Test** — missing `name` must not seal; dispatch surfaces error
```sql
\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
DO $$ BEGIN
  PERFORM ckp.dispatch('input.demo.Hello.create',
    '{"action":"create","trace_id":"tx-bad","data":{}}'::jsonb);
  RAISE EXCEPTION 'TEST FAILED: dispatch should reject missing name';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE '%missing required%' THEN RAISE NOTICE 'PASS: %', SQLERRM;
  ELSE RAISE; END IF; END $$;
SELECT count(*)=0 AS no_write FROM ckp.instances WHERE id LIKE 'i-tx-bad-%';
```
- [ ] **Step 2: Run** — Expected: `PASS: …missing required: name`, `no_write|t`.
- [ ] **Step 3: Commit**
```bash
git add sql/test/s2_dispatch_reject.sql
git commit -m "test: ckp.dispatch rejects shape-violating body atomically"
```

### Task T-10: bgworker bridge — drain NATS PUB → `ckp.dispatch` → publish

**Files:** Modify `src/nats/server.rs`, `src/bgworker.rs`

- [ ] **Step 1: server.rs** — capture PUB payloads (read the declared byte count) and expose an inbound channel `tokio::sync::mpsc::Sender<(String, Vec<u8>)>` passed into `run`; on a PUB to a subject, send `(subject, payload)`. (Add the payload read: after the `PUB` control line, read `n` bytes + CRLF from the `BufReader`. Replace the `lines()` framing with a manual read of control-line then payload.) Keep MSG fanout for SUB clients.
- [ ] **Step 2: bgworker.rs** — the SPI side: the dedicated thread owns the server + a `mpsc::Receiver`; the **bgworker main thread** drains it and runs:
```rust
// Pseudocode shape — main bgworker loop, per inbound (subject, payload):
// BackgroundWorker::transaction(|| {
//   Spi::connect(|c| {
//     let res = c.select("SELECT ckp.dispatch($1, $2::jsonb)", None,
//        &[subject.into(), String::from_utf8_lossy(&payload).into()])?;
//     // res JSONB -> publish to res->>'out_topic' and result.<kernel>
//   })
// })
```
Implement: a `static INBOX: OnceLock<Mutex<Receiver<(String,Vec<u8>)>>>`; in `tick()` `try_recv()` all pending and for each call `BackgroundWorker::transaction` + `Spi::connect` running `SELECT ckp.dispatch($1,$2::jsonb)`, then hand the returned JSONB (with `out_topic`) back to the server thread via a reply channel for the NATS publish to both `out_topic` and `result.<kernel>`.
- [ ] **Step 3: fmt + build** `cargo fmt --all -- --check && cargo build --no-default-features --features embedded-nats 2>&1 | tail -3` — Expected: fmt 0; build ok.
- [ ] **Step 4: Commit**
```bash
git add src/nats/server.rs src/bgworker.rs
git commit -m "feat: bgworker drains NATS PUB -> ckp.dispatch (SPI) -> publish result"
```

### Task T-9: End-to-end slice test — publish in, sealed, result out

**Files:** Create `sql/test/s2_slice.sh`

- [ ] **Step 1: Harness**
```bash
#!/usr/bin/env bash
set -euo pipefail
S=nats://127.0.0.1:4222
nats --server $S sub 'event.demo.Hello.created' --count=1 > /tmp/pgck_slice.out 2>&1 &
SUB=$!; sleep 1
nats --server $S pub 'input.demo.Hello.create' \
  '{"action":"create","trace_id":"tx-slice-1","data":{"name":"Ada","lang":"en"}}'
wait $SUB
grep -q '"trace_id":"tx-slice-1"' /tmp/pgck_slice.out \
  && grep -q '"status":"created"' /tmp/pgck_slice.out \
  && echo "SLICE OK" || { echo "SLICE FAIL"; cat /tmp/pgck_slice.out; exit 1; }
```
- [ ] **Step 2: Prep + run** (pod up, ext created, ckp.boot+load_kernel+bootstrap_kernel, GUCs set), then `bash sql/test/s2_slice.sh`
Expected: `SLICE OK`.
- [ ] **Step 3: Verify the instance was sealed**
```bash
cd compose && podman compose exec postgres psql -U pgck -d pgck -tc \
 "SELECT count(*) FROM ckp.instances WHERE id LIKE 'i-tx-slice-1-%';"
```
Expected: `1`.
- [ ] **Step 4: Commit**
```bash
git add sql/test/s2_slice.sh
git commit -m "test: end-to-end slice — input.* -> seal -> event.* (trace_id demux)"
```

### Task T-8: Result mirror to `result.<kernel>` (v3.7 dual-publish)

**Files:** Modify `src/bgworker.rs` (publish to both subjects)

- [ ] **Step 1:** Ensure the reply publish targets BOTH `out_topic` (from dispatch result) and `result.<kernel>` where `<kernel>` = `split_part(subject,'.',3)`. (Confirm the publish loop sends two MSGs.)
- [ ] **Step 2: Test** extend `sql/test/s2_slice.sh` logic in a new `sql/test/s2_result_mirror.sh` subscribing `result.Hello`:
```bash
#!/usr/bin/env bash
set -euo pipefail
S=nats://127.0.0.1:4222
nats --server $S sub 'result.Hello' --count=1 > /tmp/pgck_mirror.out 2>&1 &
SUB=$!; sleep 1
nats --server $S pub 'input.demo.Hello.create' \
  '{"action":"create","trace_id":"tx-mir-1","data":{"name":"Bo"}}'
wait $SUB
grep -q 'tx-mir-1' /tmp/pgck_mirror.out && echo "MIRROR OK" || { cat /tmp/pgck_mirror.out; exit 1; }
```
- [ ] **Step 3: fmt+build+run** — Expected: `MIRROR OK`.
- [ ] **Step 4: Commit**
```bash
git add src/bgworker.rs sql/test/s2_result_mirror.sh
git commit -m "feat: dual-publish result to affordance outTopic + result.<kernel> (v3.7)"
```

### Task T-7: Stage S2 gate — `just smoke-s2`

**Files:** Modify `Justfile`

- [ ] **Step 1: Add gate**
```make
smoke-s2: smoke-s3
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck \
      -c "DROP EXTENSION IF EXISTS pgck; CREATE EXTENSION pgck; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo'); SELECT set_config('ckp.project','demo',false); SELECT set_config('ckp.identity_key',md5('demo'),false); CALL ckp.bootstrap_kernel();"
    sleep 3
    cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 -f - < sql/test/s2_affordances.sql
    cd compose && {{run}} compose exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 -f - < sql/test/s2_dispatch_reject.sql
    bash sql/test/s2_slice.sh
    bash sql/test/s2_result_mirror.sh
```
- [ ] **Step 2: Run** `just smoke-s2` — Expected: all pass; `SLICE OK`, `MIRROR OK`.
- [ ] **Step 3: Commit**
```bash
git add Justfile
git commit -m "chore: just smoke-s2 — the vertical slice gate (topic conversation)"
```

### Task T-6: Mirror parser/router unit tests into CI (`cargo pgrx test` stays green)

**Files:** Modify `.github/workflows/ci.yml`

- [ ] **Step 1:** Add a `nats-unit` job that builds with `--no-default-features --features embedded-nats` and runs `cargo test --no-default-features --features embedded-nats parser router` (pure Rust, no PG). Append:
```yaml
  nats-unit:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test --no-default-features --features embedded-nats parser router
```
- [ ] **Step 2: Commit + push; watch CI**
```bash
git add .github/workflows/ci.yml
git commit -m "ci: nats-unit job runs parser+router unit tests (no PG needed)"
```
Run: watch `ci.yml` to `success` (fmt+clippy+test+nats-unit).
- [ ] **Step 3: Confirm green** before T-5.

### Task T-5: `ckp.recompile_affordances()` — live reroute on ontology change

**Files:** Modify `sql/pgck--0.1.1.sql`; Create `sql/test/s2_recompile.sql`

- [ ] **Step 1: Add the function** (re-reads affordances; the server picks up new subjects because dispatch resolves per-message via `ckp.affordances()` — recompile just re-materialises + signals)
```sql
-- Re-materialize the kernel graph and return the current affordance count.
-- Dispatch resolves affordances per-message, so a reloaded kernel TTL
-- reroutes with no restart.
CREATE OR REPLACE FUNCTION ckp.recompile_affordances(p_project TEXT DEFAULT 'demo')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_k INT := (SELECT v::int FROM ckp.config WHERE k='kernel_graph_id');
        v_n BIGINT;
BEGIN
  PERFORM pgrdf.materialize(v_k);
  SELECT count(*) INTO v_n FROM ckp.affordances(p_project);
  RETURN v_n;
END;
$$;
```
- [ ] **Step 2: Test** `sql/test/s2_recompile.sql`
```sql
\set ON_ERROR_STOP 1
SELECT ckp.recompile_affordances('demo') = 1 AS one_affordance;
```
- [ ] **Step 3: Rebuild+recreate+load; run** — Expected: `one_affordance|t`.
- [ ] **Step 4: Commit**
```bash
git add sql/pgck--0.1.1.sql sql/test/s2_recompile.sql
git commit -m "feat: ckp.recompile_affordances() — re-materialize + count (live reroute)"
```

**→ CHECKPOINT: report S2 to user (the vertical slice works end-to-end).**

---

## STAGE S1 — Grow + ship (T-4 → T-1)

### Task T-4: One-command story — `just demo`

**Files:** Modify `Justfile`

- [ ] **Step 1: Add recipe**
```make
demo: smoke-s2
    @echo "pgCK minimal CK story: topic conversation in -> governed seal -> proof-stamped out"
    nats --server nats://127.0.0.1:4222 sub 'event.demo.Hello.created' --count=1 &
    sleep 1
    nats --server nats://127.0.0.1:4222 pub 'input.demo.Hello.create' \
      '{"action":"create","trace_id":"tx-demo","data":{"name":"world"}}'
    sleep 1
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck -tc \
      "SELECT ckp.verify(id) FROM ckp.instances WHERE id LIKE 'i-tx-demo-%' LIMIT 1;"
```
- [ ] **Step 2: Run** `just demo` — Expected: the subscriber prints the proof-stamped `event.demo.Hello.created` envelope; final psql prints `t` (verify).
- [ ] **Step 3: Commit**
```bash
git add Justfile
git commit -m "feat: just demo — full minimal event-driven governed CK story"
```

### Task T-3: README quick start + spec sync

**Files:** Modify `README.md`; Modify `docs/specs/2026-05-16-pgck-core-design.md` (mark S0/dispatch realised)

- [ ] **Step 1: README** add:
```markdown
## Quick start — minimal event-driven governed core

```bash
just pgrdf-fetch && just build-ext && just compose-up
just demo   # publish input.demo.Hello.create → seal → proof-stamped event.demo.Hello.created
```

pgCK is the NATS server; the affordance in `examples/example.kernel.ttl`
binds the topic to the SHACL-gated, sealed, verifiable governed write —
all offloaded to pgRDF. No external broker.
```
- [ ] **Step 2: spec** in the core-design §3 component table, change the `src/nats/` + `src/bgworker.rs` rows from "later phase" to "realised v0.2.0".
- [ ] **Step 3: Commit**
```bash
git add README.md docs/specs/2026-05-16-pgck-core-design.md
git commit -m "docs: README quick-start + mark dispatch/NATS realised in core-design"
```

### Task T-2: Tag `v0.2.0`

**Files:** none (release)

- [ ] **Step 1: Confirm CI green on main**
Run: `gh run list --repo styk-tv/pgCK --workflow ci.yml -L 1 --json conclusion -q '.[0].conclusion'`
Expected: `success`
- [ ] **Step 2: Tag+push**
```bash
git tag -a v0.2.0 -m "pgCK v0.2.0 — minimal event-driven governed core (NATS topic conversation -> SHACL-enforced seal -> proof-stamped result)"
git push origin v0.2.0
```
- [ ] **Step 3: Watch release run to success**
Run: `gh run watch "$(gh run list --repo styk-tv/pgCK --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')" --repo styk-tv/pgCK`
Expected: 8 builds + release `success`.

### Task T-1: Completion — verify published v0.2.0

**Files:** none (acceptance — reaching here = plan complete)

- [ ] **Step 1: Anon OCI pull**
Run: `docker manifest inspect ghcr.io/styk-tv/pgck:0.2.0-pg17-arm64`
Expected: valid OCI manifest, no auth.
- [ ] **Step 2: Acceptance — confirm all true:**
  - `just demo` green from clean checkout: publish `input.demo.Hello.create` → proof-stamped `event.demo.Hello.created` (+ `result.Hello` mirror), demuxed by `trace_id`.
  - Shape-violating body → error, atomic, no instance/ledger/proof.
  - `ckp.verify` detects tamper.
  - v0.2.0 on GitHub Releases + GHCR (anon pull confirmed).
- [ ] **Step 3:** Append to project memory that the minimal event-driven governed core is complete; next plan = JetStream durable inbound stream + WSS browser listener + multi-kernel edges. **T-1 reached → plan done.**

---

## Self-review (resolved inline)

- **Spec coverage:** event-driven dispatch (your directive + dispatch contract D.1–D.5) → S2; pgCK-is-the-server (design §1A) → S3; governed seal offloaded to pgRDF (your "offload" directive, design §3/§6) → S4 + S5; v3.7 subject/affordance/envelope contract → T-13/T-12/T-8; FC.Thinker `trace_id` demux discipline → T-9; pgRDF API corrections (design §6) → T-27/T-25; compose harness + per-file bind mounts (deploy spec §1) → S5.
- **No placeholders:** every step has literal SQL/Rust/Justfile/Dockerfile/shell + exact command + expected output. (T-10 step 1–2 describe the PUB-payload framing change and the SPI bridge shape concretely with the exact channel types and the exact `SELECT ckp.dispatch($1,$2::jsonb)` call; the engineer implements the manual byte-read against `tokio::io::AsyncReadExt` — this is the one genuinely non-trivial task and is deliberately a single focused unit.)
- **Type/name consistency:** `ckp.boot`/`ckp.load_kernel`/`ckp.bootstrap_kernel`/`ckp.validate`/`ckp.seal`/`ckp.verify`/`ckp.affordances`/`ckp.dispatch`/`ckp.recompile_affordances`; GUCs `ckp.project`/`ckp.identity_key`; graph IRIs `urn:ckp:core`/`urn:ckp:<project>/kernel/ck`; subjects `input.demo.Hello.create`/`event.demo.Hello.created`/`result.Hello`; correlation `trace_id`/`tx-{uuid}`; Rust `crate::nats::{parser,router,server}`, `ClientMsg`, `Router`, feature `embedded-nats` — identical across all tasks.
- **Reverse-numbering:** T-34 (first) → T-1 (completion); count is the natural decomposition.
- **Interleaved model honored:** the vertical slice (S2) depends on the substrate (S5 seal, S3 server) but each grows minimally — the slice is the smallest end-to-end conversation, then T-8/T-5 grow dispatch + governance together.
