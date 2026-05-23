# pgCK — PostgreSQL Concept Kernel extension

**pgCK** is a PostgreSQL extension (Rust / `pgrx`, same setup as [pgRDF](https://github.com/styk-tv/pgRDF)) that **bridges from inside Postgres**: it is the Concept Kernel Protocol runtime as a database extension — NATS bridge + SHACL validator + materializer, in one place, one transaction boundary.

Spec of record: [`SPEC.CKP.3.8.MINIMAL-rc3.md`](SPEC.CKP.3.8.MINIMAL-rc3.md).

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
- **Security boundary is upstream, in Envoy**: TLS termination + **OIDC-JWT** verification happen in an **Envoy `SecurityPolicy`** at the **Azure Container App front**. Only authenticated, authorised NATS traffic reaches the pod. pgCK trusts the post-Envoy stream; it does not re-implement auth — it enforces *governance* (SHACL, signing, proof), not authentication.

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

- ✅ **Governed write path works today** (PL/pgSQL, ships as the extension's bootstrap SQL): `ckp.bootstrap_kernel` / `ckp.validate` / `ckp.seal` / `ckp.verify`. Validate → instance → signed ledger → verifiable proof, atomic, each protocol op SHACL-validated against the **core** ontology or it aborts. No CK.Compliance kernel — governance is core.
- ✅ **S3 embedded NATS server lands locally:** the `pgrx` background worker now hosts the raw NATS Core listener on `:4222`, with parser/router/server unit coverage and a compose-level `smoke-s3` round-trip gate.
- 🔨 **Next Rust focus:** wire the governed SPI dispatch bridge, WSS client, affordance compile loop (`ckp.subscribe` / `ckp.publish` / `ckp.recompile_affordances`), and the CK-graph change trigger that reroutes live.
- ⏭ ed25519 (replace the HMAC stand-in in `ckp.seal`); `postgres_fdw` → Azure swap (call sites unchanged).

## Layout

```
pgCK/
  SPEC.CKP.3.8.MINIMAL-rc3.md   spec of record
  Cargo.toml  pgck.control  Justfile  rust-toolchain.toml
  src/lib.rs            pgrx entry: _PG_init, bgworker registration, ckp.* externs
  src/bgworker.rs       embedded NATS listener host (S3); SPI dispatch bridge later
  sql/pgck--0.1.1.sql   governed write path (works now, PL/pgSQL)
  ontology/core.ttl     CKP core ontology + SHACL shapes (protocol governs itself)
  docker/               single-pod image + entrypoint
  examples/             demo kernel ttl
```

## Local build loop

The active local loop is **Docker on the `colima` context only**. `just` will start
Colima if needed and run `docker build` / `docker compose` against that context.

It builds Linux extension artifacts into `compose/extensions/pgck/` and mounts them
into the isolated compose stack.

```bash
just pgrdf-fetch     # download released pgRDF artifacts into compose/extensions/pgrdf
just build-ext       # build pgck.so + control/sql into compose/extensions/pgck
just compose-up      # start the local stack
just compose-recreate
just smoke-s4        # governed SQL gate
just smoke-s3        # governed SQL + embedded NATS gate
just psql            # psql into the compose postgres
```

The expected local bootstrap is:

```bash
colima start
docker context use colima
```

Verified locally on **2026-05-19** with the `colima` Docker context:

- Linux containers in Colima can bind-mount the macOS workspace and write artifacts
  back onto the host path.
- `compose/builder.Containerfile` builds successfully under Colima.
- The export image writes `pgck.so`, `pgck.control`, and `pgck--0.1.1.sql` back to
  the mounted host directory on the host filesystem.

Host bind mounts such as `compose/extensions/`, `compose/dev-certs/`, and the repo
workspace live on the macOS host. Docker image layers, build cache, and named volumes
still consume Colima VM disk.

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
just nats-wss-up
just smoke-nats-wss
```

Local defaults:

- TCP NATS: `nats://dev:devpass-change-me@<host>:4222`
- Browser WSS: `wss://<host>:8443`
- Monitoring: `http://<host>:8222/varz`

The generated CA certificate lives at `compose/dev-certs/ca.pem`. Trust that CA on the
other laptop before attempting browser WSS connections.
