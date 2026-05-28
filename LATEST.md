# pgCK — latest published artifacts

Two publishable surfaces ship from this repo: the PostgreSQL **extension** (oras-pulled OCI artifact) and the **pgck-web** FastAPI runtime (docker image). This file tracks the head of each on **PostgreSQL 17**. Older PG majors (14, 15, 16) are still built per release — see [Repo packages view](https://github.com/styk-tv/pgCK/pkgs/container/pgck) for the full matrix.

## pgCK extension — `v0.1.7` (PostgreSQL 17)

`oras pull ghcr.io/styk-tv/pgck:0.1.7-pg17-<arch>` → drop `lib/pgck.so` + `share/extension/{pgck.control, pgck--0.1.7.sql}` next to your `postgres:17` install.

| arch  | Pull URI                                  | Digest                                                                  | Created (UTC)       |
|-------|-------------------------------------------|-------------------------------------------------------------------------|---------------------|
| amd64 | `ghcr.io/styk-tv/pgck:0.1.7-pg17-amd64`   | `sha256:7200eb22f2c9221542caad7d56163bf198e0254937d56d575cfb9102bdc6058c` | 2026-05-28 17:46:08 |
| arm64 | `ghcr.io/styk-tv/pgck:0.1.7-pg17-arm64`   | `sha256:8bbdc3cdb574d93e27e2a6227e2675e8b50b966cc7922103f08fc4c4ab61bfb1` | 2026-05-28 17:44:33 |

|                       |                                                                          |
|-----------------------|--------------------------------------------------------------------------|
| Artifact type         | `application/vnd.styk.pgck.extension.v1`                                 |
| Tarball mirror        | https://github.com/styk-tv/pgCK/releases/tag/v0.1.7                      |
| Repo packages view    | https://github.com/styk-tv/pgCK/pkgs/container/pgck                      |
| Older PG majors       | `0.1.7-pg{14,15,16}-{amd64,arm64}` published alongside; same v0.1.7 tag  |

## pgck-web — `v0.2.3`

FastAPI runtime layer: dual-page Display / Board, `/cklib` mount for the CKClient ESM module (CK.Lib.Js v1.3 aligned), `/assets` mount for static files. Pull and run directly.

| arch  | Pull URI                                  | Also tagged       | Digest                                                                  | Created (UTC)       |
|-------|-------------------------------------------|-------------------|-------------------------------------------------------------------------|---------------------|
| amd64 | `ghcr.io/styk-tv/pgck-web:v0.2.3-amd64`   | `latest-amd64`    | `sha256:8844d536798906bf531b85b09bcb4ca396712309777f1e9c875bab5fd5a58603` | 2026-05-28 17:06:47 |
| arm64 | `ghcr.io/styk-tv/pgck-web:v0.2.3-arm64`   | `latest-arm64`    | `sha256:b665a439c1aea22bfc21297189a808964c45f34357c2b4bcae925c8e7b6d5b66` | 2026-05-28 17:09:08 |

|                       |                                                                          |
|-----------------------|--------------------------------------------------------------------------|
| Repo packages view    | https://github.com/styk-tv/pgCK/pkgs/container/pgck-web                  |
| Source                | [`web/`](./web/) (consolidated from `web_demo/` at pgck-web/v0.2.1)      |

## Pin policy

- `latest-amd64` / `latest-arm64` track the **most recent pgck-web tag**. There is no `latest` on the extension OCI artifact — pin by `pg`×`arch` explicitly.
- Tagged versions are immutable on GHCR.

See [`CHANGELOG.md`](./CHANGELOG.md) and [`RELEASE_NOTES.md`](./RELEASE_NOTES.md) for what changed per version.
