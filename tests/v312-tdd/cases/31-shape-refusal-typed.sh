#!/usr/bin/env bash
# B7 RESIDUE (found while proving the lexicon gate): the SHAPE-GATE refusal — the
# single most important refusal class — rides create_typed's catch-all as PROSE
# ('ckp.seal: payload fails the composed shape gate: …') with no refused:true and
# no sqlstate, so the envelope law (0.4.83) cannot recognize it: the registry
# matches codes, not prose. Predicted RED until the seal path refuses typed
# (error 'shape_violation', refused:true, 23514, violations as data).
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/core#Supersession\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -q '"ok": *false' || BROKEN "a Supersession missing its required supersedes SEALED: $out"
echo "$out" | grep -qi 'shape gate\|shape_violation\|MinCount' || BROKEN "refused, but not by the shape gate: $out"
if echo "$out" | grep -q '"refused": *true' && echo "$out" | grep -q '"sqlstate"'; then
  GREEN "the shape-gate refusal is typed — refused:true + sqlstate on the wire"
fi
RED "the shape-gate refusal rides as prose — no refused:true, no sqlstate; the envelope law cannot see the most important refusal class (B7 residue)"
