#!/usr/bin/env bash
# s34 — install-from-zero gate (answers oci-germination's install-cascade NOTIFY, 2026-06-11).
#
# Contract: a VIRGIN postgres-17 cluster + `CREATE EXTENSION pgck CASCADE` MUST yield a
# working governed 2-arg dispatch for a REAL `ck_participant` login session — with ZERO
# manual steps (no CALL bootstrap_kernel, no ALTER OWNER, no extra grants). The full
# board flow (boot + import_module from the shipped /ontology layout) must work, and the
# v3.9 floor must hold for the participant (no table reach, no pgrdf reach).
#
# This reproduces the exact consumer journey of ociger-ck-allinone (fresh cluster, OCI
# artifact mounts) instead of the warm compose volume the s4..s33 suite runs against.
#
# Run: just smoke-s34   (needs `just build-ext` artifacts in compose/extensions/)
set -euo pipefail

DC="${DOCKER_CONTEXT:-colima}"
NAME=pgck-s34-fresh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/compose/extensions"
# Mount the exact base-install script for each extension's declared default_version
# (NOT `ls pgrdf--*.sql | head -1` — that picks the alphabetically-first file, which
# for pgRDF >=0.6 is the `pgrdf--0.5.1--0.6.14.sql` UPGRADE script, not the install
# script; `CREATE EXTENSION ... CASCADE` on a virgin cluster needs the base install
# script matching default_version). Deriving from the control file keeps this gate
# correct across version bumps with zero edits here.
ctl_default_version() { sed -n "s/^default_version = '\(.*\)'/\1/p" "$1"; }
PGCK_SQL="pgck--$(ctl_default_version "$EXT"/pgck/share/extension/pgck.control).sql"
PGRDF_SQL="pgrdf--$(ctl_default_version "$EXT"/pgrdf/share/extension/pgrdf.control).sql"

fail() { echo "s34 FAIL: $*" >&2; exit 1; }
cleanup() { docker --context "$DC" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "s34: virgin cluster (no volume) + $PGCK_SQL + $PGRDF_SQL"
docker --context "$DC" run -d --name "$NAME" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=fresh -e POSTGRES_DB=fresh \
  -v "$EXT/pgrdf/lib/pgrdf.so":/usr/lib/postgresql/17/lib/pgrdf.so:ro \
  -v "$EXT/pgrdf/share/extension/pgrdf.control":/usr/share/postgresql/17/extension/pgrdf.control:ro \
  -v "$EXT/pgrdf/share/extension/$PGRDF_SQL":"/usr/share/postgresql/17/extension/$PGRDF_SQL":ro \
  -v "$EXT/pgck/lib/pgck.so":/usr/lib/postgresql/17/lib/pgck.so:ro \
  -v "$EXT/pgck/share/extension/pgck.control":/usr/share/postgresql/17/extension/pgck.control:ro \
  -v "$EXT/pgck/share/extension/$PGCK_SQL":"/usr/share/postgresql/17/extension/$PGCK_SQL":ro \
  -v "$ROOT/ontology":/ontology:ro \
  docker.io/library/postgres:17.4-bookworm \
  postgres -c shared_preload_libraries=pgrdf,pgck >/dev/null

# first boot initdb's then restarts; wait for STABLE readiness
for i in $(seq 1 60); do
  if docker --context "$DC" exec "$NAME" pg_isready -U postgres -d fresh >/dev/null 2>&1; then
    sleep 2
    docker --context "$DC" exec "$NAME" pg_isready -U postgres -d fresh >/dev/null 2>&1 && break
  fi
  sleep 1
  [ "$i" = 60 ] && fail "cluster never became ready"
done

SU()   { docker --context "$DC" exec -i "$NAME" psql -U postgres       -d fresh -v ON_ERROR_STOP=1 -tAc "$1"; }
PART() { docker --context "$DC" exec -i "$NAME" psql -U ck_participant -d fresh -v ON_ERROR_STOP=1 -tAc "$1"; }

# (0) the one install step a consumer runs
SU "CREATE EXTENSION pgck CASCADE;" >/dev/null
echo "s34: CREATE EXTENSION pgck CASCADE ✓"

# (1) ask-1: seal-path tables exist with NO further action
[ "$(SU "SELECT (to_regclass('ckp.instances') IS NOT NULL AND to_regclass('ckp.ledger') IS NOT NULL AND to_regclass('ckp.proof') IS NOT NULL AND to_regclass('ckp.outbox') IS NOT NULL)::text")" = "true" ] \
  || fail "(ask 1) ckp.{instances,ledger,proof,outbox} missing after CREATE EXTENSION — bootstrap is still manual"
echo "s34: tables exist out-of-the-box ✓"

# (2) THE KEYSTONE — governed 2-arg dispatch as a REAL ck_participant login, zero prep
R="$(PART "SELECT ckp.dispatch('instance.create','{\"task\":{\"target_kernel\":\"s34\",\"title\":\"fresh-install\"}}'::jsonb)->>'ok'")" \
  || fail "(asks 2/5) dispatch as ck_participant ERRORED on a fresh cluster"
[ "$R" = "true" ] || fail "(asks 2/5) dispatch as ck_participant returned ok=$R"
echo "s34: governed dispatch as ck_participant ok:true ✓"

# (3) ask-3: the documented ontology layout works (boot + module import from /ontology)
SU "CALL ckp.boot();" >/dev/null
SU "CALL ckp.import_module('task','demo'); CALL ckp.import_module('goal','demo');" >/dev/null
echo "s34: boot + import_module from shipped /ontology layout ✓"

# (4) the full legacy board verb still works for the participant after boot
R="$(PART "SELECT ckp.dispatch('task.create','{\"task\":{\"target_kernel\":\"s34\",\"title\":\"board task\",\"goal\":\"v0.4.2\"}}'::jsonb)->>'ok'")"
[ "$R" = "true" ] || fail "legacy task.create as participant returned ok=$R after boot"
echo "s34: legacy task.create as participant ok:true ✓"

# (5) the floor HOLDS for the same real login: no table reach, no pgrdf reach
if PART "SELECT count(*) FROM ckp.instances" >/dev/null 2>&1; then
  fail "FLOOR BREACH — ck_participant read ckp.instances directly"
fi
if PART "SELECT pgrdf.add_graph('urn:s34:breach')" >/dev/null 2>&1; then
  fail "FLOOR BREACH — ck_participant reached pgrdf"
fi
echo "s34: floor holds (participant: no tables, no pgrdf) ✓"

echo "s34_fresh_install: PASS"
