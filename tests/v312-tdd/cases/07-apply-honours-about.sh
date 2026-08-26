#!/usr/bin/env bash
# GOVERNANCE reads the record (VRS R-D / PASS-1 F-A / finding-1787385340368585000):
# a Proposal whose about names ANOTHER kernel must land there or refuse — never
# silently redirect into the acting kernel. Predicted RED: about is recorded
# faithfully and then ignored; the Separation Axiom survives by silent redirection.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT 'GA=' || (ckp.dispatch('kernel.germinate','{\"project\":\"tdd7a\",\"projectKind\":\"personal\",\"label\":\"tdd about probe A\"}'::jsonb)->>'ok');
SELECT 'GB=' || (ckp.dispatch('kernel.germinate','{\"project\":\"tdd7b\",\"projectKind\":\"personal\",\"label\":\"tdd about probe B\"}'::jsonb)->>'ok');
SELECT set_config('ckp.project','tdd7a',true);
SELECT 'B_BEFORE=' || count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:tdd7b/kernel/ck> { ?s ?p ?o } }');
SELECT 'PROP=' || (ckp.dispatch('kernel.propose_change','{\"proposalOp\":\"add_class\",\"about\":\"urn:ckp:tdd7b/kernel/ck\",\"body\":{\"name\":\"Tdd7Probe\"}}'::jsonb)::text);
ROLLBACK;")
echo "$out" | grep -qi "vacuous|no SHACL target" && RED "blocked by the #134 signature at germination — retest when the engine fix lands"
echo "$out" | grep -q "GA=true" || RED "germination unavailable on this bench — the about experiment needs two fresh kernels: $(echo "$out"|tail -2|cut -c1-160)"
prop_id=$(echo "$out" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$prop_id" ] || RED "germinated, but propose returned no id — apply-target flow unmeasurable in-txn: $(echo "$out" | grep PROP | cut -c1-160)"
out2=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT set_config('ckp.project','tdd7a',true);
SELECT 'APPLY=' || (ckp.dispatch('kernel.apply','{\"proposal\":\"$prop_id\"}'::jsonb)->>'ok');
SELECT 'B_AFTER=' || count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:tdd7b/kernel/ck> { ?s ?p ?o } }');
SELECT 'A_HAS_PROBE=' || count(*) FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:tdd7a/kernel/ck> { ?s ?p ?o } }');
ROLLBACK;")
echo "$out2" | grep -q "APPLY=true" || RED "apply refused before the target question could be measured: $(echo "$out2"|tail -1|cut -c1-160)"
b_after=$(echo "$out2" | sed -n 's/^B_AFTER=//p' | head -1)
if echo "$out2" | grep -q "APPLY=true" && [ "${b_after:-0}" -gt 0 ]; then
  GREEN "apply landed in the kernel its about names — F-A is fixed"
fi
RED "apply reported ok while the about-target stayed untouched — silent redirection into the acting kernel (F-A stands)"
