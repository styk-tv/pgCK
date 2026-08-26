#!/usr/bin/env bash
# R-G: the alpha write path (task.create) — dead verb held dead by the engine's
# vacuity refusal. RED = refusal stands (path unrepaired/unretired). GREEN only when
# the path is REMOVED (unknown_affordance) — never when it seals.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT ckp.dispatch('task.create','{\"task\":{\"target_kernel\":\"demo\",\"title\":\"tdd probe\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -qi "unknown_affordance" && GREEN "task.create is gone — the alpha path was retired, the honest end state"
echo "$out" | grep -q '"ok": *true' && BROKEN "task.create SEALED — the vacuous pass is back; this must never be green by sealing"
echo "$out" | grep -qi "vacuous\|no SHACL target" && RED "dead verb held dead by the vacuity refusal — repair-or-retire still owed (HANDOVER B)"
BROKEN "unexpected reply: $out"
