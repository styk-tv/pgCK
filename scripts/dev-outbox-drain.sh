#!/usr/bin/env bash
# dev-outbox-drain.sh — DEV-ONLY, Python-free outbound drain.
#
# Bridges ckp.outbox -> NATS for LOCAL development against the published
# all-in-one while its in-kernel bridge worker's NATS drain is not yet shipped
# (oci-germination §A/§B "next fix"). Substrates (web2 signage, web3 konva)
# subscribe to the SAME event.kernel.pgCK.> wire, so they are forward-compatible:
# when the published bgworker drains natively, stop this script — nothing else
# changes. This is devops tooling (shell + psql + the bundled nats CLI), NOT the
# published live path. No Python.
#
# Usage:  scripts/dev-outbox-drain.sh            (loops, drains every 500ms)
#         PGPORT=15432 NATS_URL=nats://localhost:14222 scripts/dev-outbox-drain.sh
set -uo pipefail

PGPORT="${PGPORT:-15432}"
PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-postgres}"
PGPASS="${PGPASSWORD:-postgres}"
PGDB="${PGDATABASE:-postgres}"
NATS_URL="${NATS_URL:-nats://localhost:14222}"
PSQL="psql postgresql://${PGUSER}:${PGPASS}@${PGHOST}:${PGPORT}/${PGDB}"

echo "[dev-drain] ckp.outbox -> ${NATS_URL}  (PG ${PGHOST}:${PGPORT})  — dev tooling, Python-free"
drained=0
while true; do
  rows="$($PSQL -tAF $'\x1f' -c \
    "select seq, subject, convert_from(payload,'UTF8') from ckp.outbox order by seq asc limit 100;" 2>/dev/null)"
  if [ -n "$rows" ]; then
    while IFS=$'\x1f' read -r seq subject payload; do
      [ -z "${seq:-}" ] && continue
      if printf '%s' "$payload" | nats --server "$NATS_URL" pub "$subject" \
           -H "Content-Type:application/json" -H "Ck-Seq:${seq}" "$payload" >/dev/null 2>&1; then
        $PSQL -tAc "delete from ckp.outbox where seq=${seq};" >/dev/null 2>&1
        drained=$((drained+1))
        printf '\r[dev-drain] published %d events (last: %s)        ' "$drained" "$subject"
      fi
    done <<< "$rows"
  fi
  sleep 0.5
done
