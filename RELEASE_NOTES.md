# pgCK release notes

pgCK — the Concept Kernel Protocol runtime as a PostgreSQL extension
(Rust/`pgrx`, composes pgRDF). See
[`SPEC.CKP.3.8.MINIMAL-rc3.md`](SPEC.CKP.3.8.MINIMAL-rc3.md) (protocol) and
[`SPEC.PGCK.DEPLOY.v0.1.md`](SPEC.PGCK.DEPLOY.v0.1.md) (build & deployment).

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
   oras pull ghcr.io/styk-tv/pgck:0.1.0-pg17-arm64
   ```

   This is a transport for the extension files, not a runnable image —
   they are bind-mounted onto a stock `postgres:17` per
   `SPEC.PGCK.DEPLOY.v0.1`.

## v0.1.0 (unreleased — init)

- Repository + CI/release initialization.
- Governed-write core (PL/pgSQL): `ckp.bootstrap_kernel` / `ckp.validate`
  / `ckp.seal` / `ckp.verify`.
- CKP core ontology shipped in-extension (`ontology/core.ttl`).
- Rust bgworker skeleton (embedded NATS Core server + affordance loop —
  in progress).
