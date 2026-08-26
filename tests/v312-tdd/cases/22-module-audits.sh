#!/usr/bin/env bash
# The instrument over the operational modules. wave + recon audit CLEAN; lexicon is
# PREDICTED FINDINGS=1 — 11 declared properties (lex:symptom among them) reached by
# no sh:path in ANY module: the seven-constants defect class in the module the
# fleet's finding-discipline leans on daily. RED until lexicon's shapes extend.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
A="$HERE/../audit/ontology-audit.sh"
w=$(bash "$A" "$REPO/ontology/v3.11/modules/wave.ttl"    | grep audit.verdict)
r=$(bash "$A" "$REPO/ontology/v3.11/modules/recon.ttl"   | grep audit.verdict)
l=$(bash "$A" "$REPO/ontology/v3.11/modules/lexicon.ttl")
echo "$w" | grep -q CLEAN || { echo "BROKEN: wave audit not clean: $w"; exit 3; }
echo "$r" | grep -q CLEAN || { echo "BROKEN: recon audit not clean: $r"; exit 3; }
if echo "$l" | grep -q "audit.verdict=CLEAN"; then
  echo "$l" | grep -q "unreached=0" && { echo "GREEN: all three modules audit CLEAN — lexicon's reach gap was closed"; exit 0; }
fi
echo "$l" | grep -q "unreached=11:lex:blockedBy" \
  && { echo "RED (as predicted): wave+recon CLEAN; lexicon carries 11 unreached properties incl. lex:symptom — ungated law, ours to fix"; exit 44; }
echo "BROKEN: lexicon audit changed shape (not the predicted 11): $(echo "$l" | grep unreached)"; exit 3
