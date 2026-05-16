# pgCK — Core Design

**Date:** 2026-05-16
**Status:** Approved — build target
**Spec of record it implements:** [`SPEC.CKP.3.8.MINIMAL-rc3.md`](../../../SPEC.CKP.3.8.MINIMAL-rc3.md)
**Supersedes assumptions in:** the hydrated `src/bgworker.rs` (child-process `nats-server`), `docker/` (custom image, `conceptkernel` name)

---

## 1. Purpose

pgCK is the Concept Kernel Protocol (CKP) runtime **inside PostgreSQL**: a Rust/`pgrx`
extension that composes pgRDF. It is the SHACL validator + materializer + NATS bridge,
in one transaction boundary. The CK loop lives in pgRDF (ontology layer, graphs 1 & 2);
DATA lives as native Postgres JSONB documents typed by the CK ontology. All
validation/materialization/proof happens in-database — no infrastructure control, only
messages, constraints, validation, and proofs.

This document is the approved design. It overrides four assumptions in the hydrated
scaffold:

| Hydrated scaffold assumed | This design |
|---|---|
| `nats-server` spawned as a child process (`std::process::Command`) | **NATS embedded as a hand-rolled Core server compiled into `pgck.so`**, feature-gated like `pg17`; a stock `nats-server` sidecar is used **for the dev loop only** |
| Custom Docker image built per change; extension named `conceptkernel` | **Stock `postgres:17.4-bookworm`, never rebuilt**; per-file bind mounts; extension named `pgck` |
| pgRDF built from source | pgRDF **consumed from its GitHub release** (`pgrdf-0.4.6-pg17-glibc-arm64.tar.gz`); never built here |
| Build on macOS | **Never built on macOS.** pgCK clones pgRDF's local podman builder + GitHub Actions release process verbatim |

## 2. Topology — Azure Container Apps sidecar, podman-emulated

One pod, multiple containers, socket-wired. Identical shape locally (podman compose)
and in production (Azure Container Apps):

```
POD (podman compose locally ≅ Azure Container App in prod)
┌────────────────────────────────────────────────────────────────────┐
│ container: postgres:17.4-bookworm   (stock, NEVER rebuilt)           │
│   shared_preload_libraries = pgrdf,pgck                              │
│   per-file :ro bind mounts (host compose/extensions/{pgrdf,pgck}/):  │
│     pgrdf.so / pgrdf.control / pgrdf--<ver>.sql  ← gh release v0.4.6 │
│     pgck.so  / pgck.control  / pgck--0.1.0.sql   ← pgck builder cntr │
│   DATA: Postgres JSONB instances / ledger / proof (ontology-typed)   │
│                                                                      │
│ container: nats:2.12   (DEV SIDECAR ONLY, :4222) ◀── localhost ─────┐│
│   shipped end-state: embedded in pgck.so; sidecar retired at step 5  ││
└──────────────────────────────────────────────────────────────────────┘
     pgck bgworker ── async-nats client ──▶ localhost:4222 ────────────┘
     (later) upstream post-Envoy WSS leg = a SEPARATE component, out of scope
```

Invariants:

- **No VM** (no Colima), **no macOS build**, **no runtime-container rebuild**. Iterating
  pgCK rebuilds only `pgck.so` in a throwaway builder container, then bounces Postgres.
- **Per-file bind mounts only** — never a directory mount over `$sharedir/extension`
  (that shadows `plpgsql.control` and crash-loops `initdb` on a fresh data dir; this is
  a documented pgRDF failure mode).
- The browser/CLI ↔ NATS WSS gateway and Envoy SecurityPolicy (TLS + OIDC-JWT) are a
  **separate component on a separate axis**, upstream of the pod's NATS boundary. pgCK
  trusts the post-Envoy stream; it enforces governance, not authentication.

## 3. Components

Each unit has one purpose, a defined interface, and is independently testable.

| Unit | Responsibility | Interface | Sourced / built how |
|---|---|---|---|
| pgRDF `.so` | RDF graphs, SPARQL, SHACL, OWL2RL | `pgrdf.*` SQL | **gh release download** (not built) |
| `ontology/core.ttl` | self-governing CKP shapes (Kernel/Organ/Affordance/LedgerEntry/Proof/Provenance) | loaded into pgRDF graph 1 at bring-up | ships in pgCK repo |
| Governed core `sql/pgck--0.1.0.sql` | validate → instance → ledger → proof, atomic, core-shape-checked | `ckp.bootstrap_kernel` / `ckp.validate` / `ckp.seal` / `ckp.verify` | PL/pgSQL via `extension_sql_file!`; **pgRDF API defects fixed** |
| Affordance resolver (SQL) | SPARQL the kernel CK graph → topic/shape/out-topic rows | `ckp.affordances()` | PL/pgSQL over pgRDF graph 2 |
| `compose/builder.Containerfile` | builds `pgck.so` + control + sql for linux glibc | exports to `compose/extensions/pgck/` | podman, cloned from pgRDF |
| `compose/compose.yml` | the pod: PG + nats dev sidecar + per-file bind mounts | `podman compose up` | cloned from pgRDF |
| `Justfile` | `build-ext` / `compose-up` / `smoke` / `pgrdf-fetch` | task surface | cloned from pgRDF idiom |
| `src/nats/` (`parser.rs` / `router.rs` / `server.rs`) | embedded NATS Core server (shipped end-state) | binds `:4222`; pub/sub/req-reply/wildcards/queue groups | hand-rolled, feature `embedded-nats`; later phase |
| `src/bgworker.rs` | async-nats client → SPI `ckp.seal` → publish result; recompile loop | tokio thread ↔ mpsc ↔ SPI main thread | replaces `Command::spawn` |
| pgCK `release.yml` | pgCK's own GH-release matrix (pg × arch) | tag-triggered | clone of pgRDF `release.yml`; later |

## 4. The embedded NATS server (shipped end-state)

No production pure-Rust NATS *server* crate exists. The requirement (NATS embedded as a
crate, critical, "same as pg17") is satisfied by hand-rolling a minimal NATS **Core**
server module compiled into `pgck.so`:

- **Verbs** (CRLF-framed text, per the official NATS protocol): `INFO`, `CONNECT`,
  `PING`, `PONG`, `PUB`, `SUB`, `UNSUB`, `MSG`, `+OK`, `-ERR`. `HPUB`/`HMSG` (headers)
  deferred until a kernel needs them.
- **Routing:** subject-token trie with `*` (one token) and `>` (trailing tokens)
  wildcards; queue groups (round-robin single delivery). Request/reply is free via
  reply-to passthrough — no extra server logic.
- **Explicitly out of scope:** JetStream (durability is the Postgres ledger/proof),
  clustering, accounts, leafnodes, auth/TLS (Envoy terminates upstream; the embedded
  server serves loopback/in-pod traffic only).
- **Cargo feature pattern** (mirrors pgRDF's forwarding-feature idiom; `default = []`
  forces explicit PG selection just as pgRDF does):

  ```toml
  [features]
  default = []
  pg14 = ["pgrx/pg14", "pgrx-tests/pg14"]
  pg15 = ["pgrx/pg15", "pgrx-tests/pg15"]
  pg16 = ["pgrx/pg16", "pgrx-tests/pg16"]
  pg17 = ["pgrx/pg17", "pgrx-tests/pg17"]
  pg_test = []
  embedded-nats = ["dep:tokio"]

  [dependencies]
  pgrx = "0.16"
  async-nats = "0.48"   # upstream WSS-leg client only; NOT a server
  tokio = { version = "1", features = ["rt","net","io-util","sync","time","macros"], optional = true }
  ```

- **Estimate:** ~500–800 LOC, ~1 week to production-shaped Core. Reference (read-only):
  `66Origin/nitox` test server, `ogzhanolguncu/rs_message_broker`,
  `bengsparks/nats-protocol` parser.

## 5. Threading model (pgrx bgworker)

The bgworker is one process, one main thread. SPI is only valid on that main thread
inside `BackgroundWorker::transaction(|| ...)`. Therefore:

- A **dedicated `std::thread`** (spawned once, `OnceLock`-guarded) owns a tokio
  current-thread runtime + the NATS connection (sidecar client now; embedded
  `TcpListener` later). It never calls SPI.
- The **main bgworker thread** keeps `wait_latch` / `tick` / `recompile_affordances`
  and, per inbound message drained from an `mpsc` channel, runs
  `BackgroundWorker::transaction(|| Spi::run("SELECT ckp.seal($1,$2)", ...))`.
- Results flow back over the channel to the NATS thread, published on `ckp:outTopic`.
- SIGTERM cleanly drops the runtime/listener; SIGHUP triggers `recompile_affordances`.

## 6. pgRDF composition — corrected API usage

pgRDF v0.4.6, schema `pgrdf`. The hydrated scaffold's calls are defective and must be
fixed:

- `pgrdf.sparql(q TEXT) → SETOF JSONB` — **one argument only.** The scaffold's
  `pgrdf.sparql($q$...$q$, 2)` (two-arg) fails. Drop the second arg; scope a query to a
  graph with the SPARQL `GRAPH <iri> { ... }` clause (IRI resolved through
  `pgrdf._pgrdf_graphs`). Result rows are **flat JSONB** keyed by bare variable name
  (`{"aff":"...","inTopic":"..."}`), not SPARQL-JSON `{type,value}`. Consume as
  `... FROM pgrdf.sparql(q) AS t(j jsonb)` then `j->>'var'`.
- `pgrdf.validate(data_graph_id BIGINT, shapes_graph_id BIGINT, mode DEFAULT 'native') → JSONB`
  — top-level keys include `conforms` (bool). `report->>'conforms'` is correct.
- `pgrdf.add_graph(id BIGINT, iri TEXT) → BIGINT`, `pgrdf.parse_turtle(content, graph_id BIGINT, base_iri DEFAULT NULL) → BIGINT`,
  `pgrdf.clear_graph(id BIGINT) → BIGINT`, `pgrdf.materialize(graph_id, profile DEFAULT 'owl-rl') → JSONB`
  — the scaffold's scratch-graph and validate calls match these and are correct.

Graph ids by convention: `urn:ckp:core` = 1, kernel CK graph = 2.

## 7. Build & test method (cloned from pgRDF, verbatim)

- **Local:** `compose/builder.Containerfile` runs `cargo pgrx package --no-default-features
  --features pg17` inside a `rust:bookworm` + PGDG-postgres-17 image; exports
  `pgck.so` / `pgck.control` / `pgck--0.1.0.sql` to `compose/extensions/`. The runtime
  `postgres:17.4-bookworm` container is never rebuilt — it bind-mounts those artifacts
  plus the downloaded pgRDF release artifacts per-file. `Justfile`: `pgrdf-fetch`,
  `build-ext`, `compose-up`, `smoke`.
- **CI (pgCK's own releases, later):** clone pgRDF `release.yml` — matrix `pg × arch` on
  `ubuntu-{22.04, 24.04-arm}`, `cargo pgrx package`, repack to
  `pgck-<ver>-pg<PG>-glibc-<arch>.tar.gz` (lib/ + share/extension/ + LICENSE/NOTICE/
  SHA256SUMS), publish to GitHub Releases. `ci.yml`: fmt + clippy + `cargo pgrx test`
  matrix. Toolchain: stable Rust, pgrx 0.16, PG17, `--no-default-features --features pg17`.

## 8. Sequencing

1. Reconcile naming (`conceptkernel` → `pgck` in `docker/`, entrypoint, README); fix the
   pgRDF API defects in `sql/pgck--0.1.0.sql` and `src/bgworker.rs`.
2. Clone pgRDF's harness: `compose/builder.Containerfile`, `compose/compose.yml`
   (PG17 + nats dev sidecar + per-file bind mounts), `Justfile`; script the pgRDF
   release download (`gh release download v0.4.6 --repo styk-tv/pgRDF`).
3. Prove the governed core green in the pod against the demo kernel — no NATS path yet
   (`ckp.bootstrap_kernel` / `ckp.seal` / `ckp.verify`).
4. Wire the NATS client: rewrite `src/bgworker.rs` to the dedicated-thread + tokio +
   mpsc + SPI model against the sidecar `nats-server`; prove an
   `input.demo.Hello.create` → `ckp.seal` → `event.demo.Hello.created` round-trip.
5. Hand-roll `src/nats/` Core server behind `embedded-nats`; swap the sidecar out;
   re-prove the round-trip.
6. Drop the deployment-organizing SPEC; clone `release.yml` for pgCK.

Deferred (call-site-compatible later, per rc3 §10): `postgres_fdw` → Azure swap; the
live CK-graph reroute trigger (AFTER-STATEMENT on the pgRDF quad table).

## 9. Success criteria

- The pod boots from `podman compose up` with stock `postgres:17.4-bookworm`, no image
  rebuild, both extensions loaded (`CREATE EXTENSION pgrdf; CREATE EXTENSION pgck;`).
- `ckp.seal` on the demo kernel produces a validated instance + signed ledger row +
  proof row, atomically, each core-shape-validated; `ckp.verify` returns true; a
  malformed payload aborts the transaction.
- An `input.demo.Hello.create` NATS message round-trips through the bgworker to
  `ckp.seal` and emits `event.demo.Hello.created` — first against the sidecar
  `nats-server`, then against the embedded `src/nats/` server with the sidecar removed.
- `cargo pgrx test --no-default-features --features pg17` is green in the builder
  container; fmt + clippy clean.

## 10. Out of scope

`postgres_fdw` → Azure-managed PG swap; the live CK-graph AFTER-STATEMENT reroute
trigger; ed25519 (the HMAC stand-in in `ckp.seal` stays until then); JetStream/
clustering/auth in the embedded NATS server; the WSS↔NATS gateway and Envoy
SecurityPolicy (separate component, separate axis).
