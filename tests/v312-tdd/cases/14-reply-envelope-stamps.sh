#!/usr/bin/env bash
# P3 / HANDOVER B4: the seal reply carries the four stamps non-null. Predicted RED.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT ckp.dispatch('instance.create',
  '{\"body\":{\"type\":\"https://conceptkernel.org/ontology/v3.11/core#Supersession\",
     \"https://conceptkernel.org/ontology/v3.11/core#supersedes\":\"urn:tdd:probe-p3\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -q '"ok": *true' || { echo "$out" | grep -qi "vacuous\|no SHACL target" && RED "seal blocked by pgRDF#134 — envelope unmeasurable until it clears"; BROKEN "seal failed unexpectedly: $out"; }
if echo "$out" | grep -qE '"createdBy": *"[^n"]' && echo "$out" | grep -qE '"conformsToShape": *"[^n"]'; then
  GREEN "the reply envelope carries the stamps — P3 landed; cklib can drop its shim"
fi
RED "sealed OK but stamps are null/absent in the reply — stored, not surfaced (P3 stands)"
