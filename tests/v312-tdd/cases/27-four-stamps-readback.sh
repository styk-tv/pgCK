#!/usr/bin/env bash
# JUDGEMENT READ-BACK: seal one fact, read the SAME fact back by its id, assert the
# four stamps INDIVIDUALLY — M1 createdBy, M2 producedBy (the addressed kernel's
# law), M3 sealedAtEpoch, M4 conformsToShape. Never one boolean.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
CREATE TEMP TABLE _t27 AS
  SELECT ckp.dispatch('instance.create','{\"body\":{
    \"type\":\"https://conceptkernel.org/ontology/v3.11/core#Supersession\",
    \"https://conceptkernel.org/ontology/v3.11/core#supersedes\":\"urn:tdd:probe-m4\"}}'::jsonb) AS r;
SELECT 'OK=' || (r->>'ok') FROM _t27;
SELECT 'M1=' || COALESCE(i.body->>'https://conceptkernel.org/ontology/v3.11/core#createdBy','ABSENT')
    || '|M2=' || COALESCE(i.body->>'https://conceptkernel.org/ontology/v3.11/core#producedBy','ABSENT')
    || '|M3=' || COALESCE(i.body->>'https://conceptkernel.org/ontology/v3.11/core#sealedAtEpoch','ABSENT')
    || '|M4=' || COALESCE(i.body->>'https://conceptkernel.org/ontology/v3.11/core#conformsToShape','ABSENT')
FROM ckp.instances i, _t27 t WHERE i.id = (t.r->>'id');
ROLLBACK;")
echo "$out" | grep -qi "vacuous|no SHACL target" && RED "blocked by #134 signature — retest when engine fix lands"
echo "$out" | grep -q "OK=true" || BROKEN "seal failed: $out"
line="$(echo "$out" | grep '^M1=' | head -1)"
[ -n "$line" ] || BROKEN "sealed but could not read the fact back by its id: $out"
echo "$line" | grep -q "M1=ABSENT" && BROKEN "M1 absent — unattributable: $line"
echo "$line" | grep -q "M2=ABSENT" && BROKEN "M2 absent — judged by nobody's law: $line"
echo "$line" | grep -q "M3=ABSENT" && BROKEN "M3 absent — no surface version: $line"
echo "$line" | grep -q "M4=ABSENT" && RED "sealed with M4 ABSENT — admitted, ledgered, judged by NOTHING (the fence): $line"
echo "$line" | grep -q "M2=.*demo/kernel" || BROKEN "M2 does not name the addressed kernel's law: $line"
GREEN "four stamps present, individually read: $line"
