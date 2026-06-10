#!/usr/bin/env bash
# Dev scaffold ONLY — runs the Tier-1 request/reply dispatcher locally so the
# browser tools (tutorial / board / explorer / forge) work until the Rust CKA-4
# dispatcher ships. NOT a prod component (see scripts/README.md — ops Python is
# forbidden in shipped slices; this is a local dev bridge, slated for deletion).
#
# Foreground: logs every request hit. Ctrl-C to stop. Used by .vscode/tasks.json
# ("pgCK · dev dispatcher") so the log is visible inline in VS Code.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=".venv-dispatcher"
if [ ! -x "$VENV/bin/python" ]; then
  echo "[run-dispatcher] creating $VENV + nats-py (one-time)…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip >/dev/null 2>&1 || true
  "$VENV/bin/pip" -q install nats-py
fi

# Defaults match the local pgck-allinone container (host-published ports).
export NATS_URL="${NATS_URL:-nats://127.0.0.1:14222}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-15432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGPASSWORD="${PGPASSWORD:-pgcklocal}"
export PGCK_BOARD_PROJECT="${PGCK_BOARD_PROJECT:-demo}"
export PGCK_IDENTITY_KEY="${PGCK_IDENTITY_KEY:-pgck-localhost}"

if ! command -v psql >/dev/null 2>&1; then
  echo "[run-dispatcher] WARNING: psql not on PATH — the dispatcher shells out to psql for ckp.* calls." >&2
fi

echo "[run-dispatcher] NATS=$NATS_URL  PG=$PGHOST:$PGPORT/$PGDATABASE  project=$PGCK_BOARD_PROJECT"
echo "[run-dispatcher] starting — every request prints below. Ctrl-C to stop."
exec "$VENV/bin/python" scripts/tutorial_dispatcher.py
