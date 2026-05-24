# pgCK release notes

pgCK — the Concept Kernel Protocol runtime as a PostgreSQL extension
(Rust/`pgrx`, composes pgRDF). Historical protocol and deployment drafts
are kept in the local-only `_WIP/` workspace; the public runtime surface is
this file plus the repo runtime directories and README.

## Distribution

Each `v*` tag publishes, for every `pg{14,15,16,17} × {amd64,arm64}`:

1. **GitHub Release tarball** — `pgck-<ver>-pg<PG>-glibc-<arch>.tar.gz`
   (`lib/pgck.so` + `share/extension/{pgck.control, pgck--<ver>.sql}` +
   `LICENSE` + `SHA256SUMS`). pgRDF INSTALL-spec parity.

2. **OCI artifact (public, anonymous pull)** —
   `ghcr.io/styk-tv/pgck:<ver>-pg<PG>-<arch>`. The pgCK extension files
   packaged as an OCI artifact (artifact-type
   `application/vnd.styk.pgck.extension.v1`); pull with `oras`:

   ```sh
   oras pull ghcr.io/styk-tv/pgck:0.1.2-pg17-arm64
   ```

   This is a transport for the extension files, not a runnable image —
   they are bind-mounted onto a stock `postgres:17` via the local runtime
   workflow described in `README.md`.

## v0.1.2 — aggregated browser + board surface

- **Board/browser MVP**: ships `web_demo/` (FastAPI API + browser UI), `examples/goal-task-board.kernel.ttl`, and pytest coverage for board payloads, gateway bootstrapping, live service behavior, and HTTP/UI endpoints.
- **Browser transport companion**: ships `compose/compose.nats-wss.yml`, `compose/nats/nats-server.conf`, `scripts/generate-dev-certs.sh`, and `just nats-wss-*` / `smoke-nats-wss` for the local TCP+WSS loop.
- **Runtime surface cleanup**: public runtime references now live in `README.md` and `RELEASE_NOTES.md`; deleted tracked specs under the repo root and `docs/` are intentionally retired from the shipped surface.
- **Ontology staging**: split `ontology/*.ttl` files land as alpha modeling input while `ckp.boot()` still loads `ontology/core.ttl` as the authoritative runtime ontology.

## v0.1.1 — pod harness + ontology load (S5 substrate)

The deployable pod is real and proven. For the deployment bots:
`oras pull ghcr.io/styk-tv/pgck:0.1.1-pg17-<arch>`, bind-mount onto a
stock `postgres:17.4` beside pgRDF v0.5.0.

- **Compose harness** (cloned from pgRDF): `just pgrdf-fetch` (downloads
  + SHA-verifies pgRDF v0.5.0 release), `just build-ext` (builds
  `pgck.so` in a throwaway Docker builder on the `colima` context — runtime image never
  rebuilt), `compose.yml` (stock `postgres:17.4-bookworm`, per-file
  bind mounts, `:4222` exposed), `just smoke-s5` (full idempotent
  bring-up gate).
- **Both extensions load in the pod**: `requires = 'pgrdf'`;
  `pgrdf.version()` → `0.5.0`, `pgck_version()` → `pgck 0.1.1 (rc3)`.
- **`ckp.boot()` + `ckp.load_kernel()`**: load the CKP core ontology
  and a kernel ontology into pgRDF graphs (storage/SHACL/reasoning
  fully offloaded to pgRDF v0.5.0).
- Governed-write core (PL/pgSQL): `ckp.bootstrap_kernel` /
  `ckp.validate` / `ckp.seal` / `ckp.verify` shipped (real pgRDF API
  wiring lands next).
- Rust bgworker skeleton (embedded NATS Core server + the topic-
  conversation dispatch — in progress, lands in v0.2.0).

## v0.1.0 — init

- Repository + CI/release pipeline (GitHub Release tarballs + public
  GHCR OCI artifacts), MIT licensed.
- `SELECT pgck_version()` minimal surface; governed-write bootstrap
  SQL + CKP core ontology shipped.
