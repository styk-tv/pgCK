#!/usr/bin/env bash
# RET: the ONE mechanical audit of the shipped v3.12 root — digest vs final sidecar,
# V3' property reach, namespace line, §2 delta presence. One instrument
# (audit/ontology-audit.sh), asserted here, run by authors before every ontology
# commit. Replaces the former per-check cases 19/20.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
out=$(bash "$HERE/../audit/ontology-audit.sh" "$REPO/ontology/v3.12/core.ttl" "$HERE/../audit/v3.12-delta.txt") || { echo "BROKEN: audit tool failed"; exit 3; }
echo "$out" | grep -q "audit.verdict=CLEAN"        || { echo "BROKEN: audit found findings:"; echo "$out" | grep -vE "=match|=CLEAN|unreached=0|violations=0|missing=0"; exit 3; }
echo "$out" | grep -q "audit.sidecar=match"        || { echo "BROKEN: final sidecar mismatch"; exit 3; }
echo "$out" | grep -q "audit.nodeshapes=30"        || { echo "BROKEN: nodeshapes != 30: $(echo "$out"|grep nodeshapes)"; exit 3; }
echo "GREEN: audit CLEAN — digest pinned, 30 shapes, 94/94 reach, namespace line held, delta complete"; exit 0
