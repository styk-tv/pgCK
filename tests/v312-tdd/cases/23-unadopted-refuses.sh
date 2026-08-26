#!/usr/bin/env bash
# Adoption honesty, write half: an UNADOPTED module's type must REFUSE at the gate
# ("not admitted"), never seal. GREEN = the refusal fires correctly.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/wave#Finding\",
  \"https://conceptkernel.org/ontology/v3.11/wave#findingState\":\"open\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -q '"ok": *true' && BROKEN "an UNADOPTED wave:Finding SEALED — proximity became adoption"
echo "$out" | grep -qiE "not admitted|no shape targets|unknown type|not declared" \
  && GREEN "unadopted wave:Finding refused naming admission — proximity is not adoption"
echo "$out" | grep -qi "vacuous\|no SHACL target" && RED "refused, but by the #134 vacuity signature — admission unmeasurable until it clears"
BROKEN "refused for an unstated reason: $out"
