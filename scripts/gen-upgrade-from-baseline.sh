#!/usr/bin/env bash
# gen-upgrade-from-baseline.sh — build sql/pgck--<from>--<to>.sql by EXTRACTING
# the changed definitions out of sql/pgck-baseline.sql.
#
# WHY THIS EXISTS. The baseline is the fresh-install path; the upgrade script is
# the ALTER EXTENSION path. Hand-writing both is how "a bench that enforces and a
# release that does not" happens (PASS-12 recorded it, PASS-13 measured it, and
# PASS-PROV records a self-inflicted repeat). Generating one from the other makes
# the two paths the SAME BYTES rather than two copies that agree today.
#
# It is deliberately dumb: it copies whole definitions, it does not diff. The
# author names which objects changed; the tool guarantees the copy is faithful.
#
# Usage:
#   scripts/gen-upgrade-from-baseline.sh <out.sql> <header.txt> <start-regex>...
#
# Each <start-regex> matches the FIRST line of a definition block — either the
# CREATE line, or a leading comment line when the comment is part of the change.
# Extraction runs to the CLOSING $function$ delimiter and its trailing ";".
# Counting delimiters is the only safe stop: a bare ";" occurs inside bodies, and
# stopping at the first one is the same non-greedy mistake PASS-29 recorded twice
# in one wave.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <out.sql> <header.txt> <start-regex>..." >&2
  exit 2
fi

out=$1; header=$2; shift 2
here=$(cd "$(dirname "$0")/.." && pwd)
baseline="$here/sql/pgck-baseline.sql"
[ -f "$baseline" ] || { echo "no baseline at $baseline" >&2; exit 1; }
[ -f "$header" ]   || { echo "no header at $header" >&2; exit 1; }

# awk reads the file directly and skips to FROM itself. It must NOT be fed by a
# pipe: awk's `exit` closes the read end, the writer takes SIGPIPE (141), and
# under `set -o pipefail` + `set -e` that KILLS THIS SCRIPT SILENTLY — leaving a
# STALE upgrade file behind while the fresh-install path moves on. Measured the
# hard way (PASS-30 §6): the bench and a fresh install disagreed, which is the
# exact drift class this generator exists to make impossible.
# The START LINE IS A NUMBER, not a second regex. grep and awk do not agree on
# ERE dialect — `\(` in a signature is an "illegal primary" to awk while grep
# takes it — so matching twice meant a block could be located and then silently
# not extracted. grep locates; awk counts delimiters. One job each.
awkprog='
BEGIN { on=0; d=0; closing=0 }
NR < FROM { next }
{
  if (NR == FROM) on=1
  if (!on) next
  print
  if (closing) { if ($0 ~ /^[ \t]*;[ \t]*$/) exit; else next }
  d += gsub(/\$(function|procedure)\$/, "&")
  if (d >= 2) {
    if ($0 ~ /\$(function|procedure)\$[ \t]*;[ \t]*$/) exit
    closing = 1
  }
}'

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
cat "$header" > "$tmp"

for re in "$@"; do
  # A regex may match more than one definition (overloads). Take the LAST byte
  # offset that matches and slice from there, so an explicit signature in the
  # regex is not required for the common case — but report the count, because a
  # silent pick of the wrong overload is exactly the class of defect this repo
  # keeps finding in itself.
  hits=$(grep -cE "$re" "$baseline" || true)
  if [ "$hits" -eq 0 ]; then echo "MISS: no line matches: $re" >&2; exit 1; fi
  if [ "$hits" -gt 1 ]; then echo "NOTE: $hits lines match, using the LAST: $re" >&2; fi
  ln=$(grep -nE "$re" "$baseline" | tail -1 | cut -d: -f1)
  before=$(wc -l < "$tmp")
  awk -v FROM="$ln" "$awkprog" "$baseline" >> "$tmp"
  echo >> "$tmp"
  after=$(wc -l < "$tmp")
  n=$((after - before - 1))
  # A block that came out empty, or absurdly short, means the delimiter walk
  # stopped early. Fail LOUD: a silently truncated definition is a half-applied
  # upgrade, which is worse than no upgrade at all.
  if [ "$n" -lt 5 ]; then
    echo "TRUNCATED: extracted only $n lines from line $ln for: $re" >&2
    exit 1
  fi
  echo "  + ${n}L @${ln}  $(sed -n "${ln}p" "$baseline" | cut -c1-64)" >&2
done

# Optional non-function tail (registry seeds, data fixes) — appended verbatim
# BEFORE the floor pass, because a new registry row must exist before the floor
# re-asserts grants over what it routes to.
if [ -n "${FOOTER:-}" ]; then
  [ -f "$FOOTER" ] || { echo "no FOOTER at $FOOTER" >&2; exit 1; }
  cat "$FOOTER" >> "$tmp"
  echo "  + tail $(wc -l < "$FOOTER" | tr -d ' ')L from $FOOTER" >&2
fi

cat >> "$tmp" <<'FTR'
-- Any function NEW in this version has never been covered by the Ring-1 floor.
-- The closing pass re-asserts owner + REVOKE-from-PUBLIC over everything in ckp,
-- which is the only thing standing between a new SECURITY DEFINER function and
-- PUBLIC EXECUTE — the defect B2 found when `ALL FUNCTIONS` never covered
-- procedures and four routes kept PUBLIC EXECUTE on every upgrade.
CALL ckp._enforce_internal_floor();
FTR

mv "$tmp" "$out"; trap - EXIT
echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines)" >&2
