#!/usr/bin/env bash
# A REFUSAL TEACHES THE KEY (cklib PASS-2 ISSUE-7, substrate half / HANDOVER B7):
# kernel.vote with the WRONG payload key must refuse naming the key the verb reads
# ({about: <proposal_iri>}), not merely the value it disliked (about:null). The
# hint discipline the substrate already shows on instance.create, applied to
# governance refusals. Predicted RED until the registry's teaching hints land.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT 'VOTE='||ckp.dispatch('kernel.vote','{\"proposalIri\":\"ckp://Proposal#nope\",\"value\":\"approve\"}'::jsonb)::text;
ROLLBACK;")
vote=$(echo "$out" | grep '^VOTE=')
[ -n "$vote" ] || BROKEN "vote reply unreadable: $out"
echo "$vote" | grep -q '"ok": *false' || BROKEN "a vote citing NO readable proposal did not refuse: $vote"
echo "$vote" | grep -q 'invalid_about' || BROKEN "refused, but not on the about clause: $vote"
if echo "$vote" | grep -q '"hint"'; then
  if echo "$vote" | grep -o '"hint"[^}]*' | grep -q 'about'; then
    GREEN "invalid_about now teaches the key it reads ({about: <proposal_iri>})"
  fi
  RED "a hint is present but does not name the 'about' key — teaching the wrong lesson"
fi
RED "invalid_about names the disliked value and never the expected key — the caller is left to guess (ISSUE-7 substrate half)"
