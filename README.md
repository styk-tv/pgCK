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
- 🔨 **Rust focus (this repo's reason to exist):** the `pgrx` background worker — embedded NATS server + WSS client + affordance compile loop (`ckp.subscribe` / `ckp.publish` / `ckp.recompile_affordances`) + the CK-graph change trigger that reroutes live.
- ⏭ ed25519 (replace the HMAC stand-in in `ckp.seal`); `postgres_fdw` → Azure swap (call sites unchanged).

## Layout

```
pgCK/
  SPEC.CKP.3.8.MINIMAL-rc3.md   spec of record
  Cargo.toml  pgck.control  Justfile  rust-toolchain.toml
  src/lib.rs            pgrx entry: _PG_init, bgworker registration, ckp.* externs
  src/bgworker.rs       embedded NATS server + WSS client + affordance loop (skeleton)
  sql/pgck--0.1.0.sql   governed write path (works now, PL/pgSQL)
  ontology/core.ttl     CKP core ontology + SHACL shapes (protocol governs itself)
  docker/               single-pod image + entrypoint
  examples/             demo kernel ttl
```

## Build (mirrors pgRDF)

```bash
just build      # cargo pgrx — compile the extension
just install    # install into a local PG with pgrdf present
just run        # pgrx test instance: CREATE EXTENSION pgrdf, pgck;
```

The governed core is exercisable without the bgworker; the bgworker is the NATS half and the active build target.
