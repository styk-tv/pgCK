# SPEC.PGCK.DEPLOY.v0.1 — pgCK deployment & build organization

**Status:** DRAFT — v0.1 — 2026-05-16 — build target
**Companion to:** [`SPEC.CKP.3.8.MINIMAL-rc3.md`](SPEC.CKP.3.8.MINIMAL-rc3.md) (protocol),
[`docs/superpowers/specs/2026-05-16-pgck-core-design.md`](docs/superpowers/specs/2026-05-16-pgck-core-design.md) (design)
**Scope:** how pgCK is built, packaged, and deployed — the process discipline. Not the protocol.

---

## 0. One sentence

pgCK clones pgRDF's process verbatim: a stock `postgres:17.4-bookworm` pod that is
**never rebuilt**, into which the pgRDF GitHub-release artifact and the locally-built
pgCK artifact are dropped via per-file bind mounts, socket-wired to a NATS sidecar
(dev) that is replaced by an in-`.so` embedded NATS Core server (shipped).

## 1. The deployment unit

The deployable unit is a **pod**, not an image. Locally it is a `podman compose`
project; in production it is an Azure Container App with the same container set. The
pod's Postgres container is unmodified upstream `postgres:17.4-bookworm`.

```
pod
├── postgres:17.4-bookworm        stock; shared_preload_libraries=pgrdf,pgck
│     ⇇ per-file :ro bind mounts (host paths → canonical PG 17 paths)
│         compose/extensions/pgrdf/lib/pgrdf.so          → /usr/lib/postgresql/17/lib/pgrdf.so
│         compose/extensions/pgrdf/share/extension/*     → /usr/share/postgresql/17/extension/
│         compose/extensions/pgck/lib/pgck.so            → /usr/lib/postgresql/17/lib/pgck.so
│         compose/extensions/pgck/share/extension/*      → /usr/share/postgresql/17/extension/
│         ontology/core.ttl, examples/*.ttl              → /fixtures (read-only)
└── nats:2.12                     DEV ONLY — retired once src/nats/ embedded server ships
```

**Hard rule:** per-file bind mounts only. A directory mount over
`$sharedir/extension` shadows stock `plpgsql.control` and crash-loops `initdb` on a
fresh data dir (documented pgRDF failure mode). Each file is mounted individually,
read-only, beside the stock extensions.

## 2. Artifact provenance

| Artifact | Origin | Mechanism | Rebuilt when |
|---|---|---|---|
| `pgrdf.so` / `.control` / `pgrdf--<ver>.sql` | **GitHub release** `styk-tv/pgRDF` | `gh release download v0.4.6 --repo styk-tv/pgRDF` → `pgrdf-0.4.6-pg17-glibc-arm64.tar.gz` → unpack | only on a pgRDF version bump (manual) |
| `pgck.so` / `pgck.control` / `pgck--0.1.0.sql` | **this repo** | `compose/builder.Containerfile` (podman) → exports to `compose/extensions/pgck/` | on any pgCK source change |
| `postgres:17.4-bookworm` | Docker Hub | pulled, unmodified | never |
| `nats:2.12` (dev) | Docker Hub | pulled, unmodified | never; removed at design step 5 |

pgCK is **never built on macOS**. The builder is a linux/glibc container; the host
only orchestrates podman and holds the exported artifacts.

## 3. Arch

Local host is arm64 macOS; podman runs arm64 linux containers natively. Use the
**arm64** pgRDF release asset (`pgrdf-0.4.6-pg17-glibc-arm64.tar.gz`) and build pgCK
arm64. pgCK's own release CI (clone of pgRDF `release.yml`) produces the full
`pg{14,15,16,17} × {amd64,arm64}` matrix for downstream/Azure (Azure Container Apps =
amd64).

## 4. The four process recipes (Justfile, cloned from pgRDF idiom)

| Recipe | Does | Runtime |
|---|---|---|
| `just pgrdf-fetch` | `gh release download` pgRDF v0.4.6, verify SHA256SUMS, unpack into `compose/extensions/pgrdf/` | host (`gh`) |
| `just build-ext` | podman build `compose/builder.Containerfile`; export `pgck.{so,control,sql}` to `compose/extensions/pgck/` | podman |
| `just compose-up` / `compose-down` | boot / stop the pod (PG + nats dev sidecar) | podman compose |
| `just smoke` | `pgrdf-fetch` + `build-ext` + `compose-up`; then `CREATE EXTENSION pgrdf; CREATE EXTENSION pgck;` + governed-write + NATS round-trip assertions | podman compose + psql |

Iteration loop: edit pgCK → `just build-ext` → `podman compose restart postgres`
(or `compose-down`/`compose-up` for a clean cluster). The Postgres image is never
rebuilt; only the bind-mounted `.so` changes.

## 5. Bring-up sequence (inside the pod)

1. Postgres starts with `shared_preload_libraries=pgrdf,pgck` (so the pgCK bgworker
   registers at `RecoveryFinished`).
2. `CREATE EXTENSION pgrdf;` then `CREATE EXTENSION pgck;` (pgck `requires = 'pgrdf'`).
3. pgCK install loads `ontology/core.ttl` into pgRDF graph 1 (`urn:ckp:core`);
   `pgrdf.materialize(1)`.
4. Kernel TTL (mounted, e.g. `examples/example.kernel.ttl`) loaded into graph 2;
   `pgrdf.materialize(2)`.
5. `CALL ckp.bootstrap_kernel();` creates `instances` / `ledger` / `proof` (local
   tables now; `postgres_fdw` → Azure later, call sites unchanged).
6. bgworker connects to NATS (dev sidecar `localhost:4222` now; embedded `:4222`
   listener later), SPARQL-enumerates affordances, subscribes; marks ready.

## 6. Dev → prod parity

| Concern | Local (podman compose) | Production (Azure Container Apps) |
|---|---|---|
| Pod | compose project | Container App, multi-container |
| Postgres | `postgres:17.4-bookworm`, bind mounts | same image; artifacts via init container / volume |
| pgRDF artifact | gh release, arm64 | gh release, amd64 |
| pgCK artifact | builder container, arm64 | release CI, amd64 |
| NATS | sidecar (dev) → embedded in `.so` (shipped) | embedded in `.so`; upstream WSS↔NATS = separate component, Envoy SecurityPolicy in front |
| Secrets | none (local tables) | `/secrets/azure.conn` mount; `postgres_fdw` → Azure-managed PG |

The topology is identical; only artifact arch and the durable data plane (local
tables vs Azure FDW) differ, and both are call-site-transparent per rc3.

## 7. What this spec does not cover

Protocol semantics (see rc3); the embedded NATS server internals (see core design §4);
`postgres_fdw` → Azure and the live CK-graph trigger (deferred, rc3 §10); the
WSS↔NATS gateway + Envoy SecurityPolicy (separate component, separate axis).

## 8. Status of the hydrated `docker/`

`docker/Dockerfile` + `docker/entrypoint.sh` (custom image baking pgRDF/AGE/nats,
extension named `conceptkernel`) are **superseded** by this spec's no-rebuild
bind-mount model. They are kept for history until the compose harness lands, then
removed or reduced to an Azure init-container reference.
