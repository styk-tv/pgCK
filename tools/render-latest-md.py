#!/usr/bin/env python3
"""Regenerate LATEST.md from current GHCR heads.

Called by `.github/workflows/update-latest-md.yml` AFTER provenance attestation
verification succeeds for the side it was invoked for. Re-renders the WHOLE
LATEST.md every time but only fills in the section whose `SIDE` env was set;
the other section is read from the current LATEST.md so its previously-attested
content is preserved (or, if there's none, it shows the "pending bootstrap"
placeholder).

Env:
  SIDE   ``ext`` or ``web`` — which section to (re)render from GHCR
  EXT_VER  required if SIDE=ext — extension version (no ``v`` prefix)
  WEB_VER  required if SIDE=web — pgck-web tag (with ``v`` prefix)
  GH_TOKEN  GitHub token with ``packages:read``
  GITHUB_REPOSITORY_OWNER  GH owner slug

Output: full LATEST.md content on stdout.
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Tuple

EXT_PLACEHOLDER = """## pgCK extension

> No attested release published yet — see [Repo packages view](https://github.com/styk-tv/pgCK/pkgs/container/pgck)."""

WEB_PLACEHOLDER = """## pgck-web

> No attested release published yet — see [Repo packages view](https://github.com/styk-tv/pgCK/pkgs/container/pgck-web)."""


def gh_api(path: str) -> list[dict]:
    r = subprocess.run(
        ["gh", "api", path, "--paginate"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(r.stdout)


def find_version(packages: list[dict], tag_filter: str) -> Tuple[str, str]:
    for v in packages:
        tags = v.get("metadata", {}).get("container", {}).get("tags", [])
        if tag_filter in tags:
            digest = v["name"]
            if not digest.startswith("sha256:"):
                raise SystemExit(f"unexpected digest format: {digest}")
            return digest, v.get("created_at", "")
    raise SystemExit(f"no GHCR version found with tag {tag_filter!r}")


def fmt_ts(iso: str) -> str:
    return iso.replace("T", " ").replace("Z", "").split(".")[0]


def render_ext(owner: str, ext_ver: str) -> str:
    pkgs = gh_api(f"/users/{owner}/packages/container/pgck/versions")
    amd_d, amd_t = find_version(pkgs, f"{ext_ver}-pg17-amd64")
    arm_d, arm_t = find_version(pkgs, f"{ext_ver}-pg17-arm64")
    return f"""## pgCK extension — `v{ext_ver}` (PostgreSQL 17)

`oras pull ghcr.io/styk-tv/pgck:{ext_ver}-pg17-<arch>` → drop `lib/pgck.so` + `share/extension/{{pgck.control, pgck--{ext_ver}.sql}}` next to your `postgres:17` install.

| arch  | Pull URI                                  | Digest                                                                  | Created (UTC)       |
|-------|-------------------------------------------|-------------------------------------------------------------------------|---------------------|
| amd64 | `ghcr.io/styk-tv/pgck:{ext_ver}-pg17-amd64`   | `{amd_d}` | {fmt_ts(amd_t)} |
| arm64 | `ghcr.io/styk-tv/pgck:{ext_ver}-pg17-arm64`   | `{arm_d}` | {fmt_ts(arm_t)} |

|                       |                                                                          |
|-----------------------|--------------------------------------------------------------------------|
| Artifact type         | `application/vnd.styk.pgck.extension.v1`                                 |
| Tarball mirror        | https://github.com/styk-tv/pgCK/releases/tag/v{ext_ver}                  |
| Repo packages view    | https://github.com/styk-tv/pgCK/pkgs/container/pgck                      |
| Older PG majors       | `{ext_ver}-pg{{14,15,16}}-{{amd64,arm64}}` published alongside           |
| Provenance            | SLSA Build Provenance v1 — verify with `gh attestation verify oci://ghcr.io/styk-tv/pgck:{ext_ver}-pg17-amd64 --repo styk-tv/pgCK` |"""


def render_web(owner: str, web_ver: str) -> str:
    pkgs = gh_api(f"/users/{owner}/packages/container/pgck-web/versions")
    amd_d, amd_t = find_version(pkgs, f"{web_ver}-amd64")
    arm_d, arm_t = find_version(pkgs, f"{web_ver}-arm64")
    return f"""## pgck-web — `{web_ver}`

FastAPI runtime layer: dual-page Display / Board, `/cklib` mount for the CKClient ESM module (CK.Lib.Js v1.3 aligned), `/assets` mount for static files. Pull and run directly.

| arch  | Pull URI                                  | Also tagged       | Digest                                                                  | Created (UTC)       |
|-------|-------------------------------------------|-------------------|-------------------------------------------------------------------------|---------------------|
| amd64 | `ghcr.io/styk-tv/pgck-web:{web_ver}-amd64`   | `latest-amd64`    | `{amd_d}` | {fmt_ts(amd_t)} |
| arm64 | `ghcr.io/styk-tv/pgck-web:{web_ver}-arm64`   | `latest-arm64`    | `{arm_d}` | {fmt_ts(arm_t)} |

|                       |                                                                          |
|-----------------------|--------------------------------------------------------------------------|
| Repo packages view    | https://github.com/styk-tv/pgCK/pkgs/container/pgck-web                  |
| Source                | [`web/`](./web/) (consolidated from `web_demo/` at pgck-web/v0.2.1)      |
| Provenance            | SLSA Build Provenance v1 — verify with `gh attestation verify oci://ghcr.io/styk-tv/pgck-web:{web_ver}-amd64 --repo styk-tv/pgCK` |"""


def extract_section(text: str, heading_prefix: str) -> str | None:
    """Return the contiguous section starting at ``heading_prefix`` from existing LATEST.md."""
    if not text:
        return None
    pattern = re.compile(
        rf"^{re.escape(heading_prefix)}.*?(?=^## |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    return m.group(0).rstrip() if m else None


def main() -> None:
    side = os.environ.get("SIDE", "").strip().lower()
    if side not in {"ext", "web"}:
        raise SystemExit("SIDE must be 'ext' or 'web'")

    owner = os.environ.get("GITHUB_REPOSITORY_OWNER", "styk-tv")
    current = pathlib.Path("LATEST.md").read_text() if pathlib.Path("LATEST.md").exists() else ""

    # Render the freshly-attested side; preserve the other from current LATEST.md.
    if side == "ext":
        ext_section = render_ext(owner, os.environ["EXT_VER"])
        web_section = extract_section(current, "## pgck-web") or WEB_PLACEHOLDER
    else:
        web_section = render_web(owner, os.environ["WEB_VER"])
        ext_section = extract_section(current, "## pgCK extension") or EXT_PLACEHOLDER

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    out = f"""<!--
  This file is auto-generated by .github/workflows/update-latest-md.yml after a
  successful release.yml / publish-pgck-web.yml run AND after SLSA Build
  Provenance v1 attestations have been verified against the GHCR digests below.
  Each invocation refreshes the section whose upstream workflow fired and
  preserves the other section verbatim. Do NOT edit by hand — the next workflow
  run will overwrite your changes. Last refresh: {now} (side: {side}).
-->

# pgCK — latest published artifacts

Two publishable surfaces ship from this repo: the PostgreSQL **extension** (oras-pulled OCI artifact) and the **pgck-web** FastAPI runtime (docker image). This file tracks the head of each on **PostgreSQL 17**. Older PG majors (14, 15, 16) are still built per release — see [Repo packages view](https://github.com/styk-tv/pgCK/pkgs/container/pgck) for the full matrix.

{ext_section}

{web_section}

## Pin policy

- `latest-amd64` / `latest-arm64` track the **most recent pgck-web tag**. There is no `latest` on the extension OCI artifact — pin by `pg`×`arch` explicitly.
- Tagged versions are immutable on GHCR.
- Every artifact ships with a verifiable **SLSA Build Provenance v1** attestation tying it to a specific GitHub Actions workflow run on this repo. Workstation pushes are not permitted; this file does not advance unless `gh attestation verify` accepts the new digest.

See [`CHANGELOG.md`](./CHANGELOG.md) and [`RELEASE_NOTES.md`](./RELEASE_NOTES.md) for what changed per version.
"""
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
