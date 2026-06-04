#!/usr/bin/env bash
# pgck-root-redirect.sh — make https://pgck.localhost/ land on the web2 studio.
#
# The published all-in-one serves its docroot at /app (so /assets/* and /cklib/*
# resolve) but ships no /app/index.html, so a bare GET / returns 404. web2 is the
# main app, so / should redirect to /assets/web2/. This drops a root redirect into
# the running container's docroot. Re-run after any `docker run` of the container
# (the copy is ephemeral). The host Envoy is already correctly wired
# (pgck_web_upstream -> 127.0.0.1:8001); this is purely the container's root page.
#
# For the published image, oci-germination should bake this /app/index.html so the
# redirect is permanent (no docker cp needed).
set -euo pipefail
CONTAINER="${1:-pgck-allinone}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
docker cp "${HERE}/web/root-redirect.html" "${CONTAINER}:/app/index.html"
echo "[root-redirect] / -> /assets/web2/ installed in ${CONTAINER}:/app/index.html"
