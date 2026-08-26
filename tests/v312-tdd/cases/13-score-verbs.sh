#!/usr/bin/env bash
# R-C: score.top routes. Predicted RED (no score.* verb in the registry).
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT ckp.dispatch('score.top','{}'::jsonb)::text;")
echo "$out" | grep -qi "unknown_affordance\|unknown affordance" && RED "score.top → unknown_affordance — the score verbs do not exist"
echo "$out" | grep -q '"ok": *true' && GREEN "score.top answered — the score plane went live"
BROKEN "unexpected reply: $out"
