#!/usr/bin/env bash
# CKP rc3 single-pod entrypoint: embedded NATS + Postgres + extensions + governed-write bring-up.
set -euo pipefail

: "${CKP_PROJECT:=demo}"
: "${CKP_CORE_TTL:=/usr/share/conceptkernel/core.ttl}"
: "${CKP_KERNEL_TTL:=/ontology/kernel.ttl}"
: "${POSTGRES_PASSWORD:=ckp}"
export POSTGRES_PASSWORD

# 1. embedded NATS broker (WSS/TCP) in background
nats-server -p 4222 &
echo "[ckp] nats-server up on :4222"

# 2. Postgres in background via the stock entrypoint
docker-entrypoint.sh postgres &
until pg_isready -q; do sleep 1; done
echo "[ckp] postgres ready"

PSQL=(psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}")

# 3. extensions
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pgrdf;"
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS age;"           || echo "[ckp] AGE optional — skipped"
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw;"
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS conceptkernel;"

# 4. load CKP CORE ontology into graph 1 (self-governance), kernel ontology into graph 2
"${PSQL[@]}" -c "SELECT pgrdf.add_graph(1,'urn:ckp:core');"
"${PSQL[@]}" -v ttl="$(cat "$CKP_CORE_TTL")" -c "SELECT pgrdf.parse_turtle(:'ttl',1,'urn:ckp:core#');"
"${PSQL[@]}" -c "SELECT pgrdf.materialize(1);"

if [ -f "$CKP_KERNEL_TTL" ]; then
  "${PSQL[@]}" -c "SELECT pgrdf.add_graph(2,'urn:ckp:${CKP_PROJECT}/kernel/ck');"
  "${PSQL[@]}" -v ttl="$(cat "$CKP_KERNEL_TTL")" -c "SELECT pgrdf.parse_turtle(:'ttl',2,'urn:ckp:kernel#');"
  "${PSQL[@]}" -c "SELECT pgrdf.materialize(2);"
  echo "[ckp] kernel ontology loaded from $CKP_KERNEL_TTL"
else
  echo "[ckp] no kernel.ttl mounted — core-only governance demo mode"
fi

# 5. governed-write bring-up (local tables now; swap to FDW→Azure when /secrets/azure.conn present)
"${PSQL[@]}" -c "CALL ckp.bootstrap_kernel();"
"${PSQL[@]}" -c "SELECT set_config('ckp.identity_key', md5('${CKP_PROJECT}-identity'), false);"
echo "[ckp] governed write path ready: ckp.seal / ckp.verify"

echo "[ckp] POD READY — project=${CKP_PROJECT}"
wait -n
