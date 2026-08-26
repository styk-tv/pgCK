#!/usr/bin/env bash
# run.sh — three-state runner (M1 made mechanical, protocol adopted from pgRDF's
# lib-tdd). Exit 0 = GREEN, 44 = RED-as-predicted (a suite PASS), other = BROKEN.
# The runner exits non-zero iff any case is BROKEN.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FILTER="${1:-}"
green=0; red=0; broken=0; brokens=""

for case_sh in "$HERE"/cases/*.sh; do
  name="$(basename "$case_sh" .sh)"
  [ -n "$FILTER" ] && [[ "$name" != "$FILTER"* ]] && continue
  out="$(bash "$case_sh" 2>&1)"; rc=$?
  case $rc in
    0)  green=$((green+1));  printf '  \033[32mGREEN \033[0m %s — %s\n' "$name" "${out##*$'\n'}" ;;
    44) red=$((red+1));      printf '  \033[33mRED   \033[0m %s — %s\n' "$name" "${out##*$'\n'}" ;;
    *)  broken=$((broken+1)); brokens="$brokens $name"
        printf '  \033[31mBROKEN\033[0m %s (rc=%s)\n%s\n' "$name" "$rc" "$out" ;;
  esac
done

echo "----------------------------------------------------------------------"
echo "v312-tdd: green $green · red-as-predicted $red · BROKEN $broken"
[ $broken -eq 0 ] || { echo "BROKEN:$brokens — stop and look."; exit 1; }
exit 0
