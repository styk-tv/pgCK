#!/usr/bin/env bash
# #56: at least one sealed ckp:Affordance exists. Predicted RED (0 on shipped bits).
source "$(dirname "$0")/../lib.sh"
n=$(Q "SELECT count(*) FROM ckp.instances WHERE body->>'type' LIKE '%core#Affordance';")
case "$n" in
  0) RED "0 sealed Affordances — capability routed, declared by nothing (#56 open)" ;;
  [1-9]*) GREEN "$n sealed Affordance(s) — #56 is closing; verify derivedBy next" ;;
  *) BROKEN "count failed: $n" ;;
esac
