#!/usr/bin/env bash
# PROOFS: every sealed fact carries at least its hmac proof row; proofs are PLURAL
# by design (N rows per fact, keyed by about); verified selects by METHOD.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT 'FACTS=' || count(DISTINCT about) FROM ckp.proof;
SELECT 'ORPHANS=' || count(*) FROM ckp.instances i WHERE NOT EXISTS
  (SELECT 1 FROM ckp.proof p WHERE p.about = i.id);
SELECT 'METHODS=' || string_agg(DISTINCT method, ',') FROM ckp.proof;")
echo "$out" | grep -q "FACTS=0" && RED "no proof rows at all — the evidence plane is empty on this bench"
o=$(echo "$out" | grep -o "ORPHANS=[0-9]*" | cut -d= -f2)
[ "$o" = "0" ] || BROKEN "$o sealed instances carry NO proof row — sealed without evidence: $out"
echo "$out" | grep -q "hmac" || BROKEN "no hmac method among proofs: $out"
GREEN "every instance carries a proof row; methods present: $(echo "$out"|grep -o 'METHODS=.*') — the evidence plane holds"
