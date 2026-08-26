#!/usr/bin/env bash
# R-E: any ckp:Run sealed, ever. Predicted RED (occurrent branch empty fleet-wide).
source "$(dirname "$0")/../lib.sh"
n=$(Q "SELECT count(*) FROM ckp.instances WHERE body->>'type' LIKE '%core#Run';")
case "$n" in
  0) RED "0 Runs — the substrate records outcomes, not happenings" ;;
  [1-9]*) GREEN "$n Run(s) sealed — attributed compute has begun" ;;
  *) BROKEN "count failed: $n" ;;
esac
