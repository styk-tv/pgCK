#!/usr/bin/env bash
# s14_ci_a1_sidecar.sh — CI-A-1 Track A ship-it (SPEC.ROADMAP.v3.9.CHECKLIST index 21).
#
# The canonical CKP v3.9 §7 exit demonstration: a SIDECAR psql connecting AS
# ck_participant — a REAL connection, the exact F-H "agent with DB credentials"
# shape, never SET ROLE — holds EXACTLY ONE capability: ckp.dispatch. pgrdf.* and
# direct table access are permission denied. "The bypass that voided the seal floor
# now lands on the seal floor."
#
# Run (extension built/booted by the smoke harness): bash sql/test/s14_ci_a1_sidecar.sh
set -uo pipefail

export DOCKER_CONTEXT="${DOCKER_CONTEXT:-colima}"
COMPOSE_PROJECT="${PGCK_COMPOSE_PROJECT:-pgck}"
cd "$(dirname "$0")/../../compose"

as_participant() {
  docker compose -p "$COMPOSE_PROJECT" exec -T postgres \
    psql -U ck_participant -d pgck -v ON_ERROR_STOP=1 -tAc "$1" 2>&1
}

fail() { echo "s14_ci_a1_sidecar: FAIL — $1"; exit 1; }

# (0) Confirm we are really connecting AS ck_participant (a real session, not SET ROLE).
who=$(as_participant "SELECT current_user")
rc=$?
[ $rc -ne 0 ] && fail "ck_participant could not log in: $who"
[ "$who" != "ck_participant" ] && fail "sidecar session is '$who', expected ck_participant"
echo "s14: connected as ck_participant (real session) ✓"

# (1) ckp.dispatch SUCCEEDS — the one capability.
out=$(as_participant "SELECT ckp.dispatch('instances.count','ckp://Kernel#demo','{}'::jsonb,'urn:ckp:participant:s14')->>'ok'")
rc=$?
[ $rc -ne 0 ] && fail "ckp.dispatch denied to ck_participant (the door must be open): $out"
[ "$out" != "true" ] && fail "ckp.dispatch did not return ok=true: $out"
echo "s14: ckp.dispatch -> ok ✓"

# (2)-(4) Everything else is permission denied.
expect_denied() {
  local what="$1" sql="$2" out rc
  out=$(as_participant "$sql"); rc=$?
  [ $rc -eq 0 ] && fail "$what SUCCEEDED for ck_participant (floor leaked)"
  echo "$out" | grep -qiE 'permission denied' || fail "$what failed but NOT with permission-denied: $out"
  echo "s14: $what -> permission denied ✓"
}

expect_denied "pgrdf.sparql"      "SELECT pgrdf.sparql('ASK { ?s ?p ?o }')"
expect_denied "pgrdf.materialize" "SELECT pgrdf.materialize(1)"
expect_denied "SELECT ckp.instances" "SELECT count(*) FROM ckp.instances"

echo "s14_ci_a1_sidecar: PASS"
