# pgCK — PostgreSQL Concept Kernel extension

**pgCK** is a PostgreSQL extension (Rust / `pgrx`, same setup as [pgRDF](https://github.com/styk-tv/pgRDF)) that **bridges from inside Postgres**: it is the Concept Kernel Protocol runtime as a database extension — NATS bridge + SHACL validator + materializer, in one place, one transaction boundary.

Public runtime reference lives in this README, [`RELEASE_NOTES.md`](RELEASE_NOTES.md), [`CHANGELOG.md`](CHANGELOG.md), and the shipped runtime files under `compose/`, `ontology/`, `examples/`, `sql/`, and `web/`. Working draft specs, planning notes, and helper material are intentionally kept in a local-only `_WIP/` directory and are not part of the public repo surface.

## What it is

| | |
|---|---|
| **Repo** | `pgCK` |
| **Extension name** | `pgck` (Postgres lowercase convention) |
| **SQL surface schema** | `ckp.*` (protocol prefix; matches ontology prefix `ckp:`) |
| **Language / build** | Rust + `pgrx` — same toolchain shape as pgRDF |
| **Requires** | `pgrdf` (RDF graphs, SPARQL, SHACL, OWL2RL). `age` optional. `postgres_fdw` for the durable data plane. |

pgCK does not replace pgRDF — it **composes** it. pgRDF holds the ontology + runs SHACL/SPARQL; pgCK governs operations, owns NATS, and materialises ontology → operational schema/routing.

## Two requirements (the focus)

### 1. NATS — embedded **server** *and* **client**

- **Embedded NATS server** (not just a client): pgCK runs an in-pod NATS server that is the message fabric for **every concept kernel in the pod for the project**. Kernels publish/subscribe locally with no external broker.
- **NATS client**: pgCK also runs a NATS client that takes messages **from the gateway over WSS** and feeds them straight into the database governed path. The gateway → pod hop is plain NATS-over-WSS; pgCK is the consumer that lands it in Postgres.
- **Security boundary is upstream, in Envoy**: TLS termination + **OIDC-JWT** verification happen in an **Envoy `SecurityPolicy`** at the **Azure Container App front**. Only authenticated, authorised NATS traffic reaches the pod. pgCK trusts the post-Envoy stream; it does not re-implement auth — it enforces *governance* (SHACL, HMAC attestation, proof), not authentication.

```
WSS client ──TLS──▶ Envoy SecurityPolicy (TLS + OIDC-JWT)  ──NATS/WSS──▶  POD
                    [Azure Container App front]                           │
                                                                          ▼
                                          pgCK NATS client ──▶ embedded NATS server
                                                                          │
                                          all project concept kernels ◀──┘
                                                                          │
                                          pgCK governed write (SHACL → instance → ledger → proof)
                                                                          ▼
                                          Postgres (pgrdf · age · pgck) ──fdw──▶ Azure-managed PG
```

### 2. PostgreSQL-client-driven extension

pgCK is invoked through the **ordinary PostgreSQL wire protocol** — any client (psql, asyncpg, sqlx, JDBC, the NATS bridge itself) calls the `ckp.*` functions. There is no separate application server. The extension *is* the runtime; the database connection *is* the API. The NATS bridge is just one such client, running inside the same Postgres as a `pgrx` background worker.

## Status

- ✅ **Governed write path** (PL/pgSQL, ships as the extension's bootstrap SQL): `ckp.bootstrap_kernel` / `ckp.validate` / `ckp.seal` / `ckp.verify`. Validate → instance → HMAC-authenticated ledger → verifiable proof, atomic, each protocol op SHACL-validated against the **core** ontology or it aborts. Governance is built into the core; no separate governance kernel.
- ✅ **Embedded NATS server:** the `pgrx` background worker hosts the raw NATS Core listener on `:4222`, with parser/router/server unit coverage and a compose-level `smoke-s3` round-trip gate.
- ✅ **CKP v3.9 Critical Isolation** (`v0.4.1`, attested): one governed door — `ckp.dispatch(verb, payload)` — over a Postgres role floor where the connecting role holds *exactly* `EXECUTE ckp.dispatch` and can reach no table or internal directly. On the floor: a sealed affordance registry as the routing authority, an apply-time plan compiler with epoch invalidation, a governance type plane (propose → vote → apply), and an enumerable typed read surface (`instance.query` / `instance.reach` / `instance.transition` / `instance.snapshot` / `concept.match`). Every read is typed and bounded; no caller SQL/SPARQL expression position is reachable.
- 🔨 **Next Rust focus:** the gateway→pod NATS-over-WSS client feeding the dispatch door, the outbound reply path, and the CK-graph change trigger that recompiles affordances and reroutes live.
- ⏭ ed25519 (replace the shipped `hmac+sha256` proof method in `ckp.seal` / `ckp.verify`); `postgres_fdw` → Azure swap (call sites unchanged).

## Layout

The public repo surface keeps runtime files at the root. `_WIP/` is reserved for local-only draft material and is intentionally ignored.

```
pgCK/
  README.md  RELEASE_NOTES.md
  .vscode/tasks.json    VS Code task-driven local loop
  Cargo.toml  pgck.control  Justfile  rust-toolchain.toml
  compose/              Colima-targeted compose runtime + browser NATS/WSS stack
  docker/               single-pod image + entrypoint
  examples/             demo kernel ttl files
  ontology/             `core.ttl` plus initial split modeling slices
  sql/                  extension SQL + smoke gates
  src/                  pgrx entrypoints and embedded NATS runtime
  tests/                runtime and web checks
  web/                  FastAPI API + web UI (`web/app.py`)
```

Historical planning and design drafts have been moved out of the public surface and into local-only `_WIP/`.

`ontology/core.ttl` remains the runtime-authoritative ontology loaded by `ckp.boot()`. The new split files under `ontology/*.ttl` are the first manual modeling pass for rc-07/rc-08 linkage work and are not yet wired into boot-time loading. The Goal/Task board demo still uses transitional string and projection fields for runtime convenience; those fields are current runtime state, not canonical long-term graph truth.

## Local build loop

The active local loop is **Docker on the `colima` context only**. `just` will start
Colima if needed and run `docker build` / `docker compose` against that context.

It builds Linux extension artifacts into `compose/extensions/pgck/` and mounts them
into the isolated compose stack.

```bash
just pgrdf-fetch     # download released pgRDF artifacts into compose/extensions/pgrdf
just build-ext       # build pgck.so + control/sql into compose/extensions/pgck
just compose-up      # detached CLI bring-up
just compose-up-fg   # foreground attach; matches VS Code task behavior
just compose-recreate
just compose-recreate-fg
just smoke-s4        # governed SQL gate
just smoke-s3        # governed SQL + embedded NATS gate
just psql            # psql into the compose postgres
```

If host port `5432` is already occupied on your machine, export `POSTGRES_PORT`
before running the compose, smoke, or `psql` tasks. For example:

```bash
export POSTGRES_PORT=55432
```

The expected local bootstrap is:

```bash
colima start
docker context use colima
```

Verified locally on **2026-05-24** with the `colima` Docker context:

- Linux containers in Colima can bind-mount the macOS workspace and write artifacts
  back onto the host path.
- `compose/builder.Containerfile` builds successfully under Colima.
- The export image writes `pgck.so`, `pgck.control`, and `pgck--0.1.2.sql` back to
  the mounted host directory on the host filesystem.

Runtime bind mounts such as `compose/extensions/`, `compose/dev-certs/`, `ontology/`,
and `examples/` live on the macOS host under the repo workspace. PostgreSQL data now
defaults to the named Docker volume `pgdata`, which avoids Colima bind-mount ownership
failures while keeping the kernel-loading paths host-mounted under the repo workspace.
Docker image layers, build cache, and named volumes still consume Colima VM disk.

## VS Code tasks

The repo ships `.vscode/tasks.json` for a foreground, task-driven local loop. The long-running tasks use foreground processes rather than detached compose commands, so closing the VS Code terminal stops the service:

- `pgck: colima-up`
- `pgck: build-ext`
- `pgck: compose-up`
- `pgck: compose-down`
- `pgck: compose-recreate`
- `pgck: smoke-s4`
- `pgck: smoke-s3`
- `pgck: psql`
- `pgck: nats-wss-up`
- `pgck: nats-wss-down`
- `pgck: smoke-nats-wss`
- `pgck: webui`

`pgck: webui` runs the same FastAPI app that serves both the browser UI and the API surface.

## Local browser WSS loop

For cross-laptop browser testing, the repo now carries a **separate local-only NATS
WSS stack**. It does not publish anything and it does not replace the current pgCK
compose loop. It uses the same Docker-on-Colima local runtime.

Generate local dev certs first. Include the LAN DNS name or IP that the other laptop
will use to reach this machine:

```bash
PGCK_WSS_CERT_HOSTS=localhost,my-macbook.local \
PGCK_WSS_CERT_IPS=127.0.0.1,192.168.1.50 \
just nats-wss-certs
```

Then boot the browser-facing NATS service:

```bash
just nats-wss-up        # detached CLI bring-up
just nats-wss-up-fg     # foreground attach; matches VS Code task behavior
just smoke-nats-wss
```

Local defaults:

- TCP NATS: `nats://dev:devpass-change-me@<host>:4223`
- Browser WSS: `wss://<host>:8443`
- Monitoring: `http://<host>:8222/varz`

The generated CA certificate lives at `compose/dev-certs/ca.pem`. Trust that CA on the
other laptop before attempting browser WSS connections.

## pgck-web OCI Layer

The `pgck-web` artifact is a non-runnable OCI layer that serves two browser entry points (display demo + tasks board) via FastAPI. It is designed to be grafted into the [oci-germination](https://github.com/sporaxis-com/oci-germination) supervisor runtime.

### Building Locally

```bash
bash compose/layers/pgck-web/build.sh dev
```

This builds a local OCI image tagged `pgck-web:dev-{amd64,arm64}` (depending on your architecture).

### Publishing

Push a tag to trigger the release workflow:

```bash
git tag pgck-web/v0.1.0
git push origin pgck-web/v0.1.0
```

GitHub Actions will:
1. Build multi-arch OCI images (amd64 + arm64)
2. Push to `ghcr.io/styk-tv/pgck-web:v0.1.0-{amd64,arm64}`
3. Generate SBOMs for supply-chain security
4. Notify oci-germination of the new layer

### Integration with oci-germination

See [oci-germination](https://github.com/sporaxis-com/oci-germination) for instructions on how to add this layer to the supervisor-based runtime pod.
