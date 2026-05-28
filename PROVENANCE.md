# Build provenance & release policy

## Hard rules

1. **All builds and all GHCR pushes run on GitHub Actions only.** Workstation `oras push`, `docker push`, `gh release create`, or any equivalent local-credential publish is prohibited at every tier.
2. **`LATEST.md` MUST NOT carry any version that was published manually or that lacks a verifiable SLSA Build Provenance v1 attestation.** If `gh attestation verify` rejects (or has no record of) the digest in question, that digest is not "the latest" — the file stays where it was. There is no manual-edit exception to this rule, not even to seed initial state. When no attested release has been produced yet, `LATEST.md` says so plainly.
3. **The only allowed write to `LATEST.md` is from `.github/workflows/update-latest-md.yml`,** which renders the file only after `gh attestation verify` accepts every digest it is about to advertise. Any other write is treated as drift and will be reverted by the next workflow run.

Everything else in this document explains how those rules are enforced.

---

Every artifact this repo publishes — the pgCK extension OCI artifacts and the pgck-web docker images — is built and pushed **exclusively** by GitHub Actions. Workstation pushes are not permitted at any tier.

## What's enforced

| Surface | Build / push performed by | Provenance |
|---|---|---|
| `ghcr.io/styk-tv/pgck:<ver>-pg<PG>-<arch>` (extension OCI artifact) | `release` workflow on `v*` tag push | [SLSA Build Provenance v1](https://slsa.dev/spec/v1.0/provenance) via [`actions/attest-build-provenance@v1`](https://github.com/actions/attest-build-provenance), pushed as an OCI referrer |
| `ghcr.io/styk-tv/pgck-web:<ver>-<arch>` (FastAPI image) | `Publish pgck-web OCI Layer` workflow on `pgck-web/v*` tag push | SLSA Build Provenance v1, same flow |
| `https://github.com/styk-tv/pgCK/releases/tag/v<ver>` (tarballs) | `release` workflow's final job | Tarballs are repackaged from the pgrx build output of the same workflow run that attested the OCI artifact |
| `LATEST.md` at the repo root | `update-latest-md` workflow on successful `workflow_run` of the above two | Refuses to advance unless `gh attestation verify` accepts every digest it's about to publish |

If `gh attestation verify` rejects an artifact, `LATEST.md` stays where it was. That's how a workstation push gets caught — it can't produce a valid GitHub-issued OIDC attestation.

## Verifying a release locally

```sh
# Extension OCI artifact (oras-pulled)
gh attestation verify oci://ghcr.io/styk-tv/pgck:0.1.7-pg17-amd64 \
  --repo styk-tv/pgCK

# pgck-web docker image
gh attestation verify oci://ghcr.io/styk-tv/pgck-web:v0.2.3-amd64 \
  --repo styk-tv/pgCK
```

A successful verify means:

- Signed by GitHub's Fulcio CA against the OIDC token of a specific workflow run
- That workflow run is in `styk-tv/pgCK`
- The signature is recorded in Sigstore's Rekor transparency log
- The subject digest matches the artifact you pulled

## Cutting a release (the only allowed flow)

1. Bump versions:
   - `Cargo.toml::package.version`
   - `pgck.control::default_version`
   - `src/lib.rs::pgck_version()` return literal + its test assertion
   - `src/nats/server.rs::INFO` constant + its test assertion
   - `src/lib.rs::extension_sql_file!("../sql/pgck--<new>.sql", …)`
   - `sql/pgck--<old>.sql` rename → `sql/pgck--<new>.sql`
   - Add an upgrade marker `sql/pgck--<old>--<new>.sql` (empty if no schema change)
2. Commit.
3. Tag: `git tag -a v<new> -m "<short>"` (or `pgck-web/v<new>` for the web layer).
4. Push the tag: `git push origin <tag>`.

GitHub Actions takes over. There is no step in this flow that requires `oras push`, `docker push`, `gh release create`, or any local-token credential.

## Hooks that block accidental local pushes

The repo's `.gitignore` keeps OCI credentials out of the tree, and the release Justfile recipes do not have `oras push` or `docker push` lines. If you find yourself reaching for either: stop, push the tag instead, and let CI publish.

## Audit trail

- Workflow source: `.github/workflows/{release,publish-pgck-web,update-latest-md}.yml`
- Attestation generator: `actions/attest-build-provenance@v1` (Sigstore-backed)
- Verifier: `gh attestation verify` (built into `gh` 2.49+)
- Renderer: `tools/render-latest-md.py`
