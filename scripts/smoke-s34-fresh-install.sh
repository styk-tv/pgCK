#!/usr/bin/env bash
# s34 — install-from-zero gate (answers oci-germination's install-cascade NOTIFY, 2026-06-11).
#
# Contract: a VIRGIN postgres-18 cluster + `CREATE EXTENSION pgck CASCADE` MUST yield a
# working governed 2-arg dispatch for a REAL `ck_participant` login session — with ZERO
# manual steps (no CALL bootstrap_kernel, no ALTER OWNER, no extra grants). The full
# board flow (boot + import_module from the shipped /ontology layout) must work, and the
# v3.9 floor must hold for the participant (no table reach, no pgrdf reach).
#
# v3.11 / pgRDF 0.6.25 ordering: BEFORE boot arms the enforcement surface, a governed
# write FAILS CLOSED (the engine no longer passes conformant-against-nothing). The
# keystone dispatch therefore runs AFTER boot; the pre-boot refusal is itself asserted.
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
  -v "$EXT/pgrdf/lib/pgrdf.so":/usr/lib/postgresql/18/lib/pgrdf.so:ro \
  -v "$EXT/pgrdf/share/extension/pgrdf.control":/usr/share/postgresql/18/extension/pgrdf.control:ro \
  -v "$EXT/pgrdf/share/extension/$PGRDF_SQL":"/usr/share/postgresql/18/extension/$PGRDF_SQL":ro \
  -v "$EXT/pgck/lib/pgck.so":/usr/lib/postgresql/18/lib/pgck.so:ro \
  -v "$EXT/pgck/share/extension/pgck.control":/usr/share/postgresql/18/extension/pgck.control:ro \
  -v "$EXT/pgck/share/extension/$PGCK_SQL":"/usr/share/postgresql/18/extension/$PGCK_SQL":ro \
  -v "$ROOT/ontology":/ontology:ro \
  docker.io/library/postgres:18-trixie \
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

# (2a) FAIL-CLOSED PRE-BOOT — v3.11 / pgRDF 0.6.25: an absent shapes surface
# no longer yields a vacuous conforms=true (the conformant-against-nothing
# hole is closed engine-side). Before boot arms the gate, a governed write
# MUST refuse — the old contract ("seal works with zero prep") was standing
# on exactly the vacuous pass this version exists to kill.
R="$(PART "SELECT ckp.dispatch('instance.create','{\"task\":{\"target_kernel\":\"s34\",\"title\":\"fresh-install\"}}'::jsonb)->>'ok'")" \
  || fail "(ask 2a) pre-boot dispatch ERRORED (should refuse cleanly, ok=false)"
[ "$R" = "false" ] || fail "(ask 2a) pre-boot governed write must FAIL CLOSED (no shapes loaded), got ok=$R"
echo "s34: pre-boot governed write refused — fail-closed, not vacuous ✓"

# (2b) the documented arming step: boot + module import from /ontology.
# Still zero MANUAL prep in the consumer sense — no grants, no bootstrap_kernel,
# no ALTER OWNER; boot is the first-start step every consumer image runs.
SU "CALL ckp.boot();" >/dev/null
echo "s34: boot from the shipped v3.11 /ontology layout ✓"

# 0.4.40: the board pair is RETIRED, so this step now asserts the REFUSAL rather
# than the import. ckp:Task and ckp:Goal do not exist in the v3.11 root, and a
# module reaches a surface only through a sealed ckp:Adoption naming its digest.
# A refusal is a result: it must name the retirement, not report a missing file.
IMP_OUT="$(SU "CALL ckp.import_module('task','demo');" </dev/null 2>&1 || true)"
case "$IMP_OUT" in
  *"RETIRED, not missing"*) : ;;
  *"could not open file"*)  fail "import_module('task') failed on a MISSING FILE — the retirement must be named, not discovered by absence" ;;
  *)                        fail "import_module('task') did not refuse with the retirement reason; got: $IMP_OUT" ;;
esac
echo "s34: retired board module refuses WITH A REASON ✓"

# (2c) THE KEYSTONE — governed 2-arg dispatch as a REAL ck_participant login,
# now against an ARMED gate.
# 0.4.40: the keystone seals a type the v3.11 ROOT declares, not the retired
# board pair. ckp:Supersession is the minimal one — SupersessionShape requires
# exactly ckp:supersedes (IRI, minCount 1) — so this exercises the whole chain
# (participant login -> dispatch -> admitted-type -> SHACL gate -> seal) without
# depending on a kernel being loaded. The old payload was {"task":{…}}, which
# minted …/v3.7/Task and only ever passed because the #46 allowance waved it
# through; it is now correctly refused, which is the point of deleting it.
# 0.4.64: unattributed seals REFUSE — the mint is gone. On the door the trusted
# ingress sets ckp.requester from the verified bearer (TR-02); this raw login
# has no ingress, so it DECLARES its identity the sanctioned way. (At SQL level
# the GUC is declared-not-verified by design — the cryptographic floor is the
# door; SQL access was always full trust.)
R="$(PART "SELECT ckp.dispatch('instance.create','{\"type\":\"https://conceptkernel.org/ontology/v3.11/core#Supersession\",\"supersedes\":\"urn:ckp:s34/probe\"}'::jsonb)->>'ok' FROM (SELECT set_config('ckp.requester','s34-participant',true)) _id")" \
  || fail "(ask 2c) dispatch as ck_participant ERRORED on a fresh cluster"
[ "$R" = "true" ] || fail "(ask 2c) dispatch as ck_participant returned ok=$R"
echo "s34: governed dispatch as ck_participant ok:true (v3.11 type, gated) ✓"

# (4) 0.4.42 — the board is DOMAIN vocabulary now, so a fresh install that has
# booted but loaded NO KERNEL cannot create board tasks: urn:ckp:board/Task is
# declared by examples/example.kernel.ttl, which ckp.load_kernel puts into
# urn:ckp:<project>/kernel/ck. No kernel, no shape, no admitted type — R2 refuses
# it fail-closed. This is the assertion that flipped when the #46 transitional
# allowance was deleted: it previously demanded ok:true, which only ever held
# because every …/ontology/v3.7/% type was waved past the admitted-type check and
# then took a VACUOUS conforms:true from a gate that targeted nothing.
R="$(PART "SELECT ckp.dispatch('task.create','{\"task\":{\"target_kernel\":\"s34\",\"title\":\"board task\",\"goal\":\"v0.4.2\"}}'::jsonb)->>'ok'")" || R="errored"
[ "$R" != "true" ] || fail "board task.create SEALED on a fresh install with no kernel loaded — fail-closed breached"
echo "s34: board verb refused with no kernel loaded (ok=$R) — R2 holds on a virgin substrate ✓"

# (5) the floor HOLDS for the same real login: no table reach, no pgrdf reach
if PART "SELECT count(*) FROM ckp.instances" >/dev/null 2>&1; then
  fail "FLOOR BREACH — ck_participant read ckp.instances directly"
fi
if PART "SELECT pgrdf.add_graph('urn:s34:breach')" >/dev/null 2>&1; then
  fail "FLOOR BREACH — ck_participant reached pgrdf"
fi
echo "s34: floor holds (participant: no tables, no pgrdf) ✓"

echo "s34_fresh_install: PASS"
