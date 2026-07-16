# pgCK release notes

pgCK — the Concept Kernel Protocol runtime as a PostgreSQL extension
(Rust/`pgrx`, composes pgRDF). Historical protocol and deployment drafts
are kept in the local-only `_WIP/` workspace; the public runtime surface is
this file plus the repo runtime directories and README.

## Distribution

pgCK is **pg18-only** (it tracks pgRDF v0.6.20, whose `.so` requires a
glibc ≥ 2.38 base — trixie/noble). Each `v*` tag publishes, for
`pg18 × {amd64,arm64}`:

1. **GitHub Release tarball** — `pgck-<ver>-pg<PG>-glibc-<arch>.tar.gz`
   (`lib/pgck.so` + `share/extension/{pgck.control, pgck--<ver>.sql}` +
   `LICENSE` + `SHA256SUMS`). pgRDF INSTALL-spec parity.

2. **OCI artifact (public, anonymous pull)** —
   `ghcr.io/styk-tv/pgck:<ver>-pg<PG>-<arch>`. The pgCK extension files
   packaged as an OCI artifact (artifact-type
   `application/vnd.styk.pgck.extension.v1`); pull with `oras`:

   ```sh
   oras pull ghcr.io/styk-tv/pgck:0.4.22-pg18-arm64
   ```

   This is a transport for the extension files, not a runnable image —
   they are bind-mounted onto a stock `postgres:18` (trixie/noble, glibc
   ≥ 2.38) via the local runtime workflow described in `README.md`.

## Version history

The per-version release log is maintained in **[`CHANGELOG.md`](CHANGELOG.md)** — the single
authoritative changelog. Every release records *what changed* and *what tests passed*
(`PROVENANCE.md` Rule 7); the attested digests for the current release are in
**[`LATEST.md`](LATEST.md)**.

- **Protocol:** CKP **v3.9** — *Critical Isolation*, finalized + locked (the official contract).
- **Extension:** **`v0.4.1`** — the v3.9 epoch shipped across `v0.3.0` → `v0.4.1` (role floor →
  sealed registry → plan compiler → governance plane → typed read surface), both arches attested.

Earlier granular per-version notes (≤ `v0.1.x`) live in git history.
