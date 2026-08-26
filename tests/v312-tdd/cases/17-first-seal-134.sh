#!/usr/bin/env bash
# THE BLOCKER: pgRDF#134 — first seal of a project refuses on the aliased composed
# graph. Predicted RED with the vacuity signature. GREEN = engine fixed → release unblocks.
# (Attribution set per the substrate's own cure text: named requester, txn-local.)
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT ckp.dispatch('instance.create',
  '{\"body\":{\"type\":\"https://conceptkernel.org/ontology/v3.11/core#Supersession\",
     \"https://conceptkernel.org/ontology/v3.11/core#supersedes\":\"urn:tdd:probe-134\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -q '"ok": *true' && GREEN "first seal SEALED — pgRDF#134 is fixed; rerun the smoke gates and resume the release"
echo "$out" | grep -qi "vacuous\|no SHACL target" && RED "first seal refused with the #134 aliasing signature — release holds"
BROKEN "seal failed for an UNSTATED reason (not the #134 signature): $out"
