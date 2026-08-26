#!/usr/bin/env bash
# GOVERNANCE reads the record (VRS R-D / SPORE §5.2): apply at quorum 1 on a
# project declared 'shared' must REFUSE naming the clause. Predicted RED: quorum
# resolves COALESCE(...,1) and projectKind is read by nothing — proposer = voter =
# applier clears on a shared project, the definition of what 'shared' forbids.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT 'GERM=' || (ckp.dispatch('kernel.germinate','{\"project\":\"tdd6\",\"projectKind\":\"shared\",\"label\":\"tdd quorum probe\"}'::jsonb)->>'ok');
SELECT set_config('ckp.project','tdd6',true);
SELECT 'PROP=' || (ckp.dispatch('kernel.propose_change','{\"proposalOp\":\"add_class\",\"about\":\"urn:ckp:tdd6/kernel/ck\",\"body\":{\"name\":\"Tdd6Probe\"}}'::jsonb)::text);
ROLLBACK;")
echo "$out" | grep -qi "vacuous|no SHACL target" && RED "blocked by the #134 signature at germination — retest when the engine fix lands"
echo "$out" | grep -q "GERM=true" || { echo "$out" | grep -qiE "refused|error" && RED "germination itself refused on this bench — quorum path unmeasurable here: $(echo "$out"|tail -2)"; BROKEN "germination failed unexpectedly: $out"; }
prop_id=$(echo "$out" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$prop_id" ] || RED "germinated, but propose did not return an id — propose/vote/apply flow unmeasurable in-txn: $(echo "$out" | grep PROP | head -1 | cut -c1-160)"
out2=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT set_config('ckp.project','tdd6',true);
SELECT 'APPLY=' || (ckp.dispatch('kernel.apply','{\"proposal\":\"$prop_id\"}'::jsonb)::text);
ROLLBACK;")
echo "$out2" | grep -qiE "quorum|shared" && GREEN "apply at quorum 1 on a shared project REFUSED naming the clause — projectKind is finally read"
echo "$out2" | grep -q '"ok": *true' && RED "apply CLEARED at quorum 1 with proposer=voter=applier on a 'shared' project — the declared contract is read by nothing"
RED "apply refused for another reason (flow constraint, not the quorum clause): $(echo "$out2" | tail -1 | cut -c1-160)"
