#!/usr/bin/env bash
# EPOCHS: an Adoption moves the enforcement surface — does anything RECORD the
# transition? Predicted RED: recomposition seals no Materialization (CKN §4.4 /
# SPORE §2.4b: same epoch number, different surface). GREEN when adoption
# materializes. Second observable, same seal: a sourceDigest of sixty-four 1s —
# bytes that exist nowhere — seals unverified (SPORE §5.1(a)).
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT 'MATS_BEFORE=' || count(*) FROM ckp.instances WHERE body->>'type' LIKE '%core#Materialization';
DO \$\$ DECLARE g bigint; BEGIN
  g := pgrdf.add_graph('urn:ckp:module:recon');
  IF pgrdf.count_quads(g) = 0 THEN
    PERFORM pgrdf.parse_turtle(pg_read_file('/ontology/v3.11/modules/recon.ttl'), g); END IF;
END \$\$;
SELECT 'ADOPT=' || (ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/core#Adoption\",
  \"https://conceptkernel.org/ontology/v3.11/core#adopts\":\"urn:ckp:module:recon\",
  \"https://conceptkernel.org/ontology/v3.11/core#intoProject\":\"urn:ckp:project:demo\",
  \"https://conceptkernel.org/ontology/v3.11/core#intoEpoch\":0,
  \"https://conceptkernel.org/ontology/v3.11/core#sourceDigest\":\"1111111111111111111111111111111111111111111111111111111111111111\"}}'::jsonb)->>'ok');
SELECT 'MATS_AFTER=' || count(*) FROM ckp.instances WHERE body->>'type' LIKE '%core#Materialization';
ROLLBACK;")
echo "$out" | grep -qi "vacuous|no SHACL target" && RED "blocked by #134 signature — retest when engine fix lands"
echo "$out" | grep -q "ADOPT=true" || BROKEN "Adoption did not seal: $out"
before="$(echo "$out" | sed -n 's/^MATS_BEFORE=//p' | head -1)"
after="$(echo "$out" | sed -n 's/^MATS_AFTER=//p' | head -1)"
[ -n "$before" ] && [ -n "$after" ] || BROKEN "could not read Materialization counts: $out"
if [ "$after" -gt "$before" ]; then
  GREEN "adoption sealed a Materialization (${before} -> ${after}) — the surface transition is on the record"
fi
RED "adoption recomposed the surface with NO Materialization (${before} -> ${after}) — the epoch cannot name what changed; and the fabricated sourceDigest sealed unverified"
