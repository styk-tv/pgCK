#!/usr/bin/env bash
# dev-callout-e2e.sh — wire proof for pgCK-owned NATS admittance (F1 pieces 3+4).
#
# Local realm, zero external infra, Python-free: a fresh Ed25519 key plays the
# realm (its JWK delivered via pgck.oidc_jwks), a fresh account nkey signs the
# callout responses, a real nats:2.12 broker runs the auth_callout stanza, and
# the -nats pgck.so is the $SYS.REQ.USER.AUTH responder.
#
# Asserts (SPEC.SECURITY §7 completion criteria, locally provable subset):
#   A  no token      → admitted anonymous: subscribe result.* DENIED (event.* only)
#   B  forged token  → same as no token (fail-open-to-anonymous, never-to-admitted)
#   C  valid token   → dispatch on input.kernel.pgCK.id.<sub>.action.task.create
#                      → result ok:true AND event.kernel.pgCK.Task.sealed carries
#                        by: urn:ckp:participant:<sub> (created_by == verified sub)
#   D  valid token, SOMEONE ELSE'S id segment → broker denies; nothing seals
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima}"
export DOCKER_CONTEXT
PROJECT=pgck-callout-e2e
COMPOSE=(docker compose -f compose/compose.yml -f compose/compose.callout-e2e.yml -p "$PROJECT")
NATS_PORT="${PGCK_E2E_NATS_PORT:-4224}"
NURL="nats://127.0.0.1:${NATS_PORT}"

command -v nats >/dev/null || { echo "FAIL: nats CLI required (brew install nats-io/nats-tools/nats)"; exit 1; }

SCRATCH="$(mktemp -d)"
cleanup() {
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "== 0/5 build the -nats .so (features pg18,nats-client) =="
# The default build-ext ships embedded-nats — NO relay/callout/publish threads.
# The e2e must run the same feature set as the released -nats artifact.
just build-ext-nats >/dev/null

echo "== 1/5 emit fresh fixtures (realm key, account nkey, tokens) =="
PGCK_E2E_DIR="$SCRATCH" cargo test --no-default-features --features "pg18,nats-client" --lib \
  -- --ignored e2e_emit_callout_fixtures >/dev/null
# shellcheck source=/dev/null
source "$SCRATCH/e2e.env"
PGCK_WORKER_PASSWORD="$(openssl rand -hex 16)"
export PGCK_E2E_SUB PGCK_E2E_ISSUER PGCK_E2E_AUDIENCE PGCK_CALLOUT_ISSUER \
       PGCK_E2E_ACCOUNT_SEED PGCK_E2E_JWKS PGCK_WORKER_PASSWORD
TOK_VALID="$(cat "$SCRATCH/token.valid")"
TOK_FORGED="$(cat "$SCRATCH/token.forged")"

echo "== 2/5 up broker + substrate (project $PROJECT) =="
"${COMPOSE[@]}" up -d --force-recreate --wait
# The docker-entrypoint's INIT phase runs a temp postgres that answers pg_isready
# on the unix socket (so --wait can pass), runs init, then RESTARTS into the real
# server — killing the first bgworker + its responder mid-flight. The temp server
# never listens on TCP, so gate on TCP: it only answers once the REAL server is up.
for i in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T postgres pg_isready -h 127.0.0.1 -U pgck >/dev/null 2>&1; then break; fi
  [ "$i" = 60 ] && { echo "FAIL: real (TCP) postgres never came up"; exit 1; }
  sleep 2
done

echo "== 3/5 bootstrap the kernel =="
"${COMPOSE[@]}" exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 -q -c \
  "DROP EXTENSION IF EXISTS pgck CASCADE; DROP EXTENSION IF EXISTS pgrdf CASCADE;
   CREATE EXTENSION pgck CASCADE; CALL ckp.boot();
   CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"

# The responder must be live before any admittance assert. A log grep is NOT
# enough: postgres's docker-entrypoint init runs a TEMP server whose bgworker
# also prints "responder live" and then dies — so probe FUNCTIONALLY: an anon
# subscribe on event.> succeeds only when a live responder shaped the admission
# (no responder ⇒ callout timeout ⇒ Authorization Violation ⇒ retry).
READY=""
for i in $(seq 1 30); do
  out="$(timeout 3 nats -s "$NURL" sub 'event.kernel.pgCK.>' 2>&1 || true)"
  if echo "$out" | grep -q "Subscribing on" && ! echo "$out" | grep -qi "violation"; then
    READY=1; break
  fi
  sleep 2
done
if [ -z "$READY" ]; then
  echo "FAIL: responder never shaped an anon admission — pgck log lines:"
  "${COMPOSE[@]}" logs postgres 2>&1 | grep -iE "pgck|nats" | tail -30
  exit 1
fi
echo "   responder live (anon admission functionally shaped)"

echo "== 4/5 admittance asserts =="
dump_evidence() {
  echo "--- assert CLI output:"; echo "$1"
  echo "--- broker log tail:"; docker logs "$("${COMPOSE[@]}" ps -q nats)" 2>&1 | tail -8
  echo "--- pgck log tail:"; "${COMPOSE[@]}" logs postgres 2>&1 | grep -iE "pgck|nats" | tail -12
}
# A: token-less → anonymous → result.* subscribe is DENIED
out_a="$(timeout 6 nats -s "$NURL" sub 'result.kernel.pgCK.>' 2>&1 || true)"
if echo "$out_a" | grep -qi "permissions violation"; then
  echo "   PASS A: anonymous is subscribe-only (result.* denied)"
else
  echo "FAIL A: anonymous connection was not restricted"; dump_evidence "$out_a"; exit 1
fi
# B: forged token → identical anonymous tier (never the claimed identity)
out_b="$(timeout 6 nats -s "$NURL" --token "$TOK_FORGED" sub 'result.kernel.pgCK.>' 2>&1 || true)"
if echo "$out_b" | grep -qi "permissions violation"; then
  echo "   PASS B: forged token drops to anonymous"
else
  echo "FAIL B: forged token was not degraded to anonymous"; dump_evidence "$out_b"; exit 1
fi

echo "== 5/5 verified dispatch (the full hop 3→6 chain) =="
SEALED="$SCRATCH/sealed.txt"; RESULT="$SCRATCH/result.txt"
timeout 25 nats -s "$NURL" --token "$TOK_VALID" sub 'event.kernel.pgCK.Task.sealed' --count 1 >"$SEALED" 2>&1 &
SEAL_PID=$!
timeout 25 nats -s "$NURL" --token "$TOK_VALID" sub 'result.kernel.pgCK.task.create' --count 1 >"$RESULT" 2>&1 &
RES_PID=$!
sleep 2
# D first (must NOT seal): publish on someone else's id segment — broker denies.
nats -s "$NURL" --token "$TOK_VALID" pub \
  "input.kernel.pgCK.id.someone-else.action.task.create" \
  '{"task":{"target_kernel":"Build","title":"e2e-must-not-seal"}}' >/dev/null 2>&1 || true
sleep 2
# C: publish on the OWN id segment — dispatches, seals, attributes.
nats -s "$NURL" --token "$TOK_VALID" pub \
  "input.kernel.pgCK.id.${PGCK_E2E_SUB}.action.task.create" \
  '{"task":{"target_kernel":"Build","title":"e2e-verified"}}' >/dev/null
wait "$SEAL_PID" || { echo "FAIL C: no Task.sealed event arrived"; cat "$SEALED"; exit 1; }
wait "$RES_PID"  || { echo "FAIL C: no dispatch result arrived"; cat "$RESULT"; exit 1; }

grep -q '"ok": *true' "$RESULT" || { echo "FAIL C: dispatch result not ok"; cat "$RESULT"; exit 1; }
echo "   PASS C1: verified dispatch returned ok:true"
grep -q "by: urn:ckp:participant:${PGCK_E2E_SUB}" "$SEALED" \
  || { echo "FAIL C: sealed event lacks by: urn:ckp:participant:${PGCK_E2E_SUB}"; cat "$SEALED"; exit 1; }
echo "   PASS C2: sealed event carries by: <verified sub> (msg.by, hop 6)"
grep -q "e2e-must-not-seal" "$SEALED" && { echo "FAIL D: a foreign-id publish sealed"; exit 1; }
CNT="$("${COMPOSE[@]}" exec -T postgres psql -U pgck -d pgck -tAc \
  "SELECT count(*) FROM ckp.instances WHERE body::text LIKE '%e2e-must-not-seal%'")"
[ "$CNT" = "0" ] || { echo "FAIL D: foreign-id publish reached the substrate"; exit 1; }
echo "   PASS D: broker denied the foreign id segment (nothing sealed)"
CBY="$("${COMPOSE[@]}" exec -T postgres psql -U pgck -d pgck -tAc \
  "SELECT body->>'https://conceptkernel.org/ontology/v3.7/created_by' FROM ckp.instances
   WHERE body::text LIKE '%e2e-verified%' LIMIT 1" 2>/dev/null || true)"
if [ "$CBY" = "urn:ckp:participant:${PGCK_E2E_SUB}" ]; then
  echo "   PASS C3: substrate created_by == verified sub (hop 4→5)"
else
  echo "FAIL C3: created_by is '${CBY}', expected urn:ckp:participant:${PGCK_E2E_SUB}"; exit 1
fi

echo "== callout e2e: ALL PASS =="
