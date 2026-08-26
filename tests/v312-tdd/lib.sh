#!/usr/bin/env bash
# lib.sh — helpers for the v312-tdd three-state suite.
# Default bench: the DISPOSABLE smoke stack (compose project 'pgck'). Any other
# bench via PGCK_TDD_PSQL — but cases may seal, and seals are forever: only
# point this at a bench you may write.
set -u

PSQL="${PGCK_TDD_PSQL:-}"
if [ -z "$PSQL" ]; then
  PSQL="docker compose -p ${PGCK_COMPOSE_PROJECT:-pgck} exec -T postgres psql -U pgck -d pgck -At -v ON_ERROR_STOP=0"
  export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima}"
  cd "$(dirname "${BASH_SOURCE[0]}")/../../compose" || exit 3
fi

# Q "sql" — run one statement, print stdout (stderr passes through for context)
Q() { echo "$1" | $PSQL 2>&1 | tr -d "\r"; }

GREEN()  { echo "GREEN: $1";  exit 0;  }
RED()    { echo "RED (as predicted): $1"; exit 44; }
BROKEN() { echo "BROKEN: $1"; exit 3;  }
