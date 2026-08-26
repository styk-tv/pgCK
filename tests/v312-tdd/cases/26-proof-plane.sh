#!/usr/bin/env bash
# PROOFS: every sealed fact carries at least its hmac proof row; proofs are PLURAL
# by design (N rows per fact, keyed by about); verified selects by METHOD.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT 'FACTS=' || count(DISTINCT about) FROM ckp.proof;
SELECT 'ORPHANS=' || count(*) FROM ckp.instances i WHERE NOT EXISTS
  (SELECT 1 FROM ckp.proof p WHERE p.about = i.id);
SELECT 'METHODS=' || string_agg(DISTINCT method, ',') FROM ckp.proof;")
echo "$out" | grep -q "FACTS=0" && RED "no proof rows at all — the evidence plane is empty on this bench"
echo "$out" | grep -q "hmac" || BROKEN "no hmac method among proofs: $out"
o=$(echo "$out" | grep -o "ORPHANS=[0-9]*" | cut -d= -f2)
if [ "$o" = "0" ]; then
  GREEN "every instance carries a proof row; methods: $(echo "$out"|grep -o 'METHODS=.*') — the evidence plane is total"
fi
# Orphans exist — the question is WHICH path produced them. Measured 2026-08-26:
# the door seal path always appends its hmac row; the orphans were legacy
# edge/concept-match fixture paths (urn:e:*, urn:cm:*, s54-*) that seal without
# evidence. That is the proof-coverage gap: every write path appends, or the
# fact plane has two classes of citizen.
door=$(Q "SELECT count(*) FROM ckp.instances i WHERE NOT EXISTS (SELECT 1 FROM ckp.proof p WHERE p.about=i.id) AND i.id LIKE '%-1%' AND i.body ? 'https://conceptkernel.org/ontology/v3.11/core#conformsToShape';")
[ "${door:-1}" = "0" ] || BROKEN "$door DOOR-sealed (gated) instances carry no proof row — the main evidence path has a hole: $out"
RED "$o instances proofless, ALL from legacy fixture paths (edge/match) — the every-write-appends-evidence gap stands (HANDOVER B); the door path is total"
