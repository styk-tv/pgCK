#!/usr/bin/env bash
# Adoption honesty, read half: wave.signals on an UNADOPTED bench must refuse
# 'module not adopted' — measured 2026-08-20 answering vacuously-empty instead.
# Predicted RED until the interim refusal (release-gate SHOULD) is coded.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT ckp.dispatch('wave.signals','{}'::jsonb)::text;")
echo "$out" | grep -qiE "not adopted|module_not_adopted|unknown_affordance" \
  && GREEN "wave.signals refuses honestly where wave is unadopted"
echo "$out" | grep -q '"ok": *true' \
  && RED "wave.signals answered (vacuously) on an unadopted bench — the ghost-read trap stands"
BROKEN "unexpected reply: $out"
