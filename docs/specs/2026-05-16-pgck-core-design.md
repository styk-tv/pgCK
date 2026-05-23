# pgCK — Core Design

**Date:** 2026-05-16
**Status:** Approved — build target
**Spec of record it implements:** [`SPEC.CKP.3.8.MINIMAL-rc3.md`](../../../SPEC.CKP.3.8.MINIMAL-rc3.md)
**Supersedes assumptions in:** the hydrated `src/bgworker.rs` (child-process `nats-server`), `docker/` (custom image, `conceptkernel` name)

---

## 1. Purpose

pgCK is the Concept Kernel Protocol (CKP) runtime **inside PostgreSQL**: a Rust/`pgrx`
extension that composes pgRDF. It is the SHACL validator + materializer **+ the NATS
server itself** (with its client inside it), in one transaction boundary. pgCK does not
connect *out* to a broker — **it is the broker**, and the master of the queue, sync,
bi-directional flow, security ("who gets what"), and the event model for every kernel
and user attached to it. The CK loop lives in pgRDF (ontology layer, graphs 1 & 2);
DATA lives as native Postgres JSONB documents typed by the CK ontology. All
validation/materialization/proof happens in-database — no infrastructure control, only
messages, constraints, validation, and proofs.

This document is the approved design. It overrides four assumptions in the hydrated
scaffold:

| Hydrated scaffold assumed | This design |
|---|---|
| `nats-server` spawned as a child process (`std::process::Command`) | **NATS embedded as a hand-rolled Core server compiled into `pgck.so`**, feature-gated like `pg17` and hosted directly by the bgworker; no separate local sidecar broker |
| Custom Docker image built per change; extension named `conceptkernel` | **Stock `postgres:17.4-bookworm`, never rebuilt**; per-file bind mounts; extension named `pgck` |
| pgRDF built from source | pgRDF **consumed from its GitHub release** (target `pgrdf-0.5.0-pg17-glibc-arm64.tar.gz`; v0.5.0 final pending, `v0.5.0-rc1` available, v0.4.6 is the last stable fallback); never built here |
| Build on macOS | **Never built on macOS.** pgCK uses a Linux builder container locally via Docker on Colima, plus a GitHub Actions release process |

## 1A. Concept Kernel specification binding (authoritative)

pgCK implements **Concept Kernel Protocol** behaviour. The conceptkernel.org v3.7
site docs are the binding protocol/subject/RBAC/event source; rc3 (single-pod,
in-database) is the binding *placement* source. Resolution rule:

> **rc3/single-pod wins on placement** (NATS embedded in pgCK; governance in-core; no
> separate CK.Compliance kernel; authentication relocated upstream to Envoy).
> **CKP v3.7 wins on protocol / subject / RBAC / event semantics** unless rc3
> explicitly supersedes it.

Authoritative v3.7 sources:
`CK-org/conceptkernel.github.io/docs/v3.7/{nats,message-envelope,auth,namespace-security,sessions,provenance,proof,edges}.md`,
`NATS-TOPICS-DESIGN.v2026.03.13.md`, `SPEC.WSS.v3.7.5-final.md`,
`SPEC.WSS.v3.8-alpha-1.md`.

**What pgCK is the master of** (synthesised; each row cites the v3.7 rule and the rc3
delta where placement supersedes):

| Concern | v3.7 rule (binding semantics) | pgCK realisation (rc3 placement) |
|---|---|---|
| **DB-protecting queue** | One NATS message at a time per subscription, in delivery order (`sessions.md:146`); durable inbound must not be evicted under load (`NATS-TOPICS-DESIGN:6-22`) | Single-threaded drain: inbound → bounded mpsc → `BackgroundWorker::transaction(\|\| Spi::run("SELECT ckp.seal …"))`. The **atomic Postgres seal-transaction is the durability boundary** — rc3 supersedes JetStream (`rc3:92`). Bounded channel = back-pressure (net-new; 3.7 had none). |
| **Sync / bi-directional** | `Trace-Id` correlation `tx-{uuid}`, echoed in every downstream message (`message-envelope.md:18`); promise / `i`-keyed demux (`REF.FC-NATS.v0.2.md:110-143`) | Request on `ckp:inTopic` → proof-stamped reply on `ckp:outTopic` (`rc3:96,156`). `stream.<K>` token streaming optional, non-durable (v3.7 deferred chapter — optional). |
| **Two connection classes** | Browser = NATS-WSS:443 via gateway, JWT-in-headers; server kernel = direct native NATS:4222, not WSS (`nats.md:42-55`) | pgCK *is* the server both attach to. Web class JWT verified upstream at Envoy; kernel class direct. User↔user = `session.{project}.{id}` fan-out (`sessions.md:14-48`). |
| **Security / authz** | Implicit-deny grants are the sole access-control source (`namespace-security.md:140,189`); authz **before** dispatch (`message-envelope.md:291`); sovereign write boundary absolute — no external identity gets `write-*` / CK-loop mutation (`namespace-security.md:206-208,254`) | **Authorization moves into pgCK's governed path**: grants + core SHACL shapes checked at seal-time / affordance-resolve. **Authentication moves upstream to Envoy** (rc3 supersedes the v3.7 "kernel verifies JWT" step). v3.7 assigned per-subject ACLs to the NATS server; pgCK's embedded NATS does no auth, so that authorization is relocated here — the single principal 3.7→rc3 relocation. |
| **Event model** | Affordance/edge → action → `outTopic`; `event.<Kernel>.<event>` naming (`SPEC.WSS.v3.7.5-final.md:461`); provenance+proof mandatory (`provenance.md:20-27`, `proof.md:256`) | Subscriptions sourced from **affordance rows** (`ckp:inTopic/outTopic/inShape`), not edge-predicate code; provenance+ledger+proof written atomically + core-shape-validated in `ckp.seal()` (`rc3:114-131`); independent `ckp.verify`. |

Subject families (v3.7, preserved on the wire): `ckp.<Kernel>.<verb>` (durable inbound —
durability realised as the Postgres seal-txn, not JetStream); `input.` / `result.` /
`event.` / `stream.<Kernel>` (core ephemeral); `session.{project}.{id}` (user↔user
fan-out, ephemeral). Non-normative-in-v3.7: `stream.*` (deferred chapter — optional);
back-pressure (acknowledged 3.7 gap — pgCK's bounded channel is net-new).

## 2. Topology — Azure Container App pod, docker-compose-on-Colima emulated

One pod, socket-wired. In the local S3 loop the compose harness is **Postgres only**
because the raw NATS listener now runs inside `pgck.so`; in production Azure still has
the upstream WSS gateway/Envoy containers in front of the database pod.

```
POD (docker compose on Colima locally; Azure Container App in prod)
┌────────────────────────────────────────────────────────────────────┐
│ container: postgres:17.4-bookworm   (stock, NEVER rebuilt)           │
│   shared_preload_libraries = pgrdf,pgck                              │
│   per-file :ro bind mounts (host compose/extensions/{pgrdf,pgck}/):  │
│     pgrdf.so / pgrdf.control / pgrdf--<ver>.sql  ← gh release v0.5.0 │
│     pgck.so  / pgck.control  / pgck--0.1.1.sql   ← pgck builder cntr │
│   DATA: Postgres JSONB instances / ledger / proof (ontology-typed)   │
│                                                                      │
│   pgck bgworker = THE NATS SERVER (embedded in pgck.so) + client     │
│     · web/user class  ── NATS-WSS from gateway (nats.ws) ──▶ :443/ws  │
│     · concept-kernel   ── direct native NATS ──▶ :4222               │
│     · queue/sync/security/events — pgCK is master of all of it       │
└──────────────────────────────────────────────────────────────────────┘
   Envoy SecurityPolicy (TLS + OIDC-JWT verify) sits UPSTREAM of the
   WSS ingress — authentication only. pgCK trusts the post-Envoy
   identity and enforces authorization + governance itself.
```

Invariants:

- **No host-native build**, **no runtime-container rebuild**. Iterating pgCK rebuilds
  only `pgck.so` in a throwaway Linux builder container running on Colima, then
  bounces Postgres.
- **Per-file bind mounts only** — never a directory mount over `$sharedir/extension`
  (that shadows `plpgsql.control` and crash-loops `initdb` on a fresh data dir; this is
  a documented pgRDF failure mode).
- **pgCK is the NATS server**, not a client to an external broker. Two connection
  classes attach to it (CKP v3.7 `docs/v3.7/nats.md:42-55`): **web/user** over
  NATS-WSS from the gateway (native `nats.ws`, JWT-in-headers), and **concept kernel**
  over a direct native connection (not WSS). User↔user is the `session.{project}.{id}`
  fan-out; kernel↔kernel rides the same server.
- **Envoy SecurityPolicy (TLS + OIDC-JWT) is authentication only**, upstream of the WSS
  ingress. pgCK trusts the post-Envoy identity and is itself the master of
  **authorization** (the v3.7 implicit-deny grants model + sovereign write boundary,
  enforced in the governed path at seal-time) and the event model. Authentication
  upstream; authorization + governance in pgCK.

## 3. Components

Each unit has one purpose, a defined interface, and is independently testable.

| Unit | Responsibility | Interface | Sourced / built how |
|---|---|---|---|
| pgRDF `.so` | RDF graphs, SPARQL, SHACL, OWL2RL | `pgrdf.*` SQL | **gh release download** (not built) |
| `ontology/core.ttl` | self-governing CKP shapes (Kernel/Organ/Affordance/LedgerEntry/Proof/Provenance) | loaded into pgRDF graph 1 at bring-up | ships in pgCK repo |
| Governed core `sql/pgck--0.1.1.sql` | validate → instance → ledger → proof, atomic, core-shape-checked | `ckp.bootstrap_kernel` / `ckp.validate` / `ckp.seal` / `ckp.verify` | PL/pgSQL via `extension_sql_file!`; **pgRDF API defects fixed** |
| Affordance resolver (SQL) | SPARQL the kernel CK graph → topic/shape/out-topic rows | `ckp.affordances()` | PL/pgSQL over pgRDF graph 2 |
| `compose/builder.Containerfile` | builds `pgck.so` + control + sql for linux glibc | exports to `compose/extensions/pgck/` | docker on Colima |
| `compose/compose.yml` | the local pod: PG + per-file bind mounts; `4222` exposed from Postgres because the listener is embedded | `docker compose up` on Colima | cloned from pgRDF, reconciled for S3 |
| `Justfile` | `build-ext` / `compose-up` / `compose-recreate` / `smoke-s4` / `smoke-s3` / `pgrdf-fetch` | task surface | cloned from pgRDF idiom |
| `src/nats/` (`parser.rs` / `router.rs` / `server.rs`) | the embedded NATS Core **server** pgCK *is* — today the raw TCP `:4222` listener with pub/sub and wildcards; WSS later | binds `:4222`; hand-rolled, feature `embedded-nats` | **realized in S3** |
| `src/bgworker.rs` | **server host**: owns the embedded NATS server lifecycle; later it also owns the single-threaded queue drain → SPI `ckp.seal` → publish | tokio thread ↔ bounded mpsc ↔ SPI main thread | repurposed (not a "client bridge"); `Command::spawn` removed |
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
- **Two listeners**: a native NATS port (`:4222`) for the concept-kernel class and a
  WSS listener for the web/user class (the gateway forwards browser `nats.ws` traffic
  in, exactly as a normal NATS WSS endpoint). pgCK *is* this server.
- **Explicitly out of scope:** JetStream (durability is the Postgres seal-transaction),
  clustering, accounts, leafnodes, TLS + JWT *authentication* (Envoy SecurityPolicy
  terminates TLS and verifies the OIDC-JWT upstream). The server does **not**
  authenticate; pgCK enforces **authorization** (the v3.7 implicit-deny grants model +
  sovereign write boundary) in the governed path at seal-time, keyed off the
  post-Envoy identity carried in message headers.
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
  async-nats = "0.48"   # client used only for outbound kernel↔kernel
                        # legs that leave the pod; pgCK IS the server (src/nats/)
  tokio = { version = "1", features = ["rt","net","io-util","sync","time","macros"], optional = true }
  ```

- **Estimate:** ~500–800 LOC, ~1 week to production-shaped Core. Reference (read-only):
  `66Origin/nitox` test server, `ogzhanolguncu/rs_message_broker`,
  `bengsparks/nats-protocol` parser.

## 5. Threading model (pgrx bgworker)

The bgworker is one process, one main thread. SPI is only valid on that main thread
inside `BackgroundWorker::transaction(|| ...)`. Therefore:

- A **dedicated `std::thread`** (spawned once, `OnceLock`-guarded, hosted by
  `bgworker.rs`) owns a tokio current-thread runtime + **the embedded NATS server's
  listeners**. S3 ships the raw native `:4222` listener; the WSS listener is deferred.
  It never calls SPI.
- The **main bgworker thread** keeps `wait_latch` / `tick` / `recompile_affordances`
  and, per inbound message drained from a **bounded** `mpsc` channel (the bounded
  channel is the DB-protecting back-pressure point — net-new vs v3.7), runs
  `BackgroundWorker::transaction(|| Spi::run("SELECT ckp.seal($1,$2)", ...))`. Drain is
  single-threaded → one message at a time, in delivery order (v3.7 `sessions.md:146`).
- **Authorization at seal-time**: before the write, the governed path checks the v3.7
  implicit-deny grants for the post-Envoy identity (from message headers) against the
  affordance's action, and the sovereign write boundary; non-conformance aborts the
  transaction. Authentication is already done upstream at Envoy.
- Results flow back over the channel to the server thread, published on `ckp:outTopic`.
- That bridge is still deferred; S3 only hosts the listener.
- SIGTERM cleanly drops the runtime/listeners; SIGHUP triggers `recompile_affordances`.

## 6. pgRDF composition — corrected API usage

pgRDF v0.5.0 (target; v0.4.6 API-compatible for the functions pgCK composes), schema
`pgrdf`. The hydrated scaffold's calls are defective and must be fixed:

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
  --features pg17,embedded-nats` inside a `rust:bookworm` + PGDG-postgres-17 image
  through Docker on the `colima` context; it exports `pgck.so` / `pgck.control` /
  `pgck--0.1.1.sql` to `compose/extensions/`. The runtime
  `postgres:17.4-bookworm` container is never rebuilt — it bind-mounts those
  artifacts plus the downloaded pgRDF release artifacts per-file. `Justfile`:
  `pgrdf-fetch`, `build-ext`, `compose-up`, `compose-recreate`, `smoke-s4`,
  `smoke-s3`.
- **CI (pgCK's own releases, later):** clone pgRDF `release.yml` — matrix `pg × arch` on
  `ubuntu-{22.04, 24.04-arm}`, `cargo pgrx package`, repack to
  `pgck-<ver>-pg<PG>-glibc-<arch>.tar.gz` (lib/ + share/extension/ + LICENSE [MIT] +
  SHA256SUMS), publish to GitHub Releases. `ci.yml`: fmt + clippy + `cargo pgrx test`
  matrix. Toolchain: stable Rust, pgrx 0.16, PG17, `--no-default-features --features pg17`.

## 8. Sequencing

1. Reconcile naming (`conceptkernel` → `pgck` in `docker/`, entrypoint, README); fix the
   pgRDF API defects in `sql/pgck--0.1.1.sql` and `src/bgworker.rs`.
2. Clone pgRDF's harness: `compose/builder.Containerfile`, `compose/compose.yml`
   (PG17 + per-file bind mounts), `Justfile`; script the pgRDF release download
   (`gh release download v0.5.0 --repo styk-tv/pgRDF`).
3. Prove the governed core green in the pod against the demo kernel — no NATS path yet
   (`ckp.bootstrap_kernel` / `ckp.seal` / `ckp.verify`).
4. Hand-roll `src/nats/` Core server behind `embedded-nats`; host it from the bgworker
   dedicated thread; prove raw `:4222` banner + pub/sub round-trip inside the pod.
5. Wire the governed SPI bridge: rewrite `src/bgworker.rs` to the dedicated-thread +
   tokio + mpsc + SPI model behind the embedded server; prove an
   `input.demo.Hello.create` → `ckp.seal` → `event.demo.Hello.created` round-trip.
6. Drop the deployment-organizing SPEC; clone `release.yml` for pgCK.

Deferred (call-site-compatible later, per rc3 §10): `postgres_fdw` → Azure swap; the
live CK-graph reroute trigger (AFTER-STATEMENT on the pgRDF quad table).

## 9. Success criteria

- The pod boots from `docker compose up` on Colima with stock
  `postgres:17.4-bookworm`, no image
  rebuild, both extensions loaded (`CREATE EXTENSION pgrdf; CREATE EXTENSION pgck;`).
- `ckp.seal` on the demo kernel produces a validated instance + signed ledger row +
  proof row, atomically, each core-shape-validated; `ckp.verify` returns true; a
  malformed payload aborts the transaction.
- The embedded NATS listener answers on `:4222`, returns the `INFO` banner + `PONG`,
  and a raw `nats sub` / `nats pub` round-trip succeeds against `pgck` itself.
- A later S2/S5 increment wires `input.demo.Hello.create` through the bgworker to
  `ckp.seal` and emits `event.demo.Hello.created`.
- `cargo pgrx test --no-default-features --features pg17` is green in the builder
  container; fmt + clippy clean.

## 10. Out of scope

`postgres_fdw` → Azure-managed PG swap; the live CK-graph AFTER-STATEMENT reroute
trigger; ed25519 (the HMAC stand-in in `ckp.seal` stays until then); JetStream/
clustering/auth in the embedded NATS server; the WSS↔NATS gateway and Envoy
SecurityPolicy (separate component, separate axis).
