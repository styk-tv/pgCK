#!/usr/bin/env bash
# The reference spore, end to end on the disposable bench: place recon, seal its
# Adoption, seal a Chunk (M4 = ChunkShape), and the negative control (section
# omitted -> MinCount refusal). The SPORE §1.3 walk as a standing case.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
DO \$\$ DECLARE g bigint; BEGIN
  g := pgrdf.add_graph('urn:ckp:module:recon');
  IF pgrdf.count_quads(g) = 0 THEN
    PERFORM pgrdf.parse_turtle(pg_read_file('/ontology/v3.11/modules/recon.ttl'), g); END IF;
END \$\$;
SELECT 'ADOPT=' || ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/core#Adoption\",
  \"https://conceptkernel.org/ontology/v3.11/core#adopts\":\"urn:ckp:module:recon\",
  \"https://conceptkernel.org/ontology/v3.11/core#intoProject\":\"urn:ckp:project:demo\",
  \"https://conceptkernel.org/ontology/v3.11/core#intoEpoch\":0,
  \"https://conceptkernel.org/ontology/v3.11/core#sourceDigest\":\"$(shasum -a 256 "$(cd "$(dirname "$0")/../../.." && pwd)/ontology/v3.11/modules/recon.ttl" 2>/dev/null | cut -d' ' -f1 || echo 0000)\"}}'::jsonb)::text;
SELECT 'CHUNK=' || ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/recon#Chunk\",
  \"https://conceptkernel.org/ontology/v3.11/recon#text\":\"tdd probe\",
  \"https://conceptkernel.org/ontology/v3.11/recon#section\":\"s1\"}}'::jsonb)::text;
SELECT 'NEG=' || ckp.dispatch('instance.create','{\"body\":{
  \"type\":\"https://conceptkernel.org/ontology/v3.11/recon#Chunk\",
  \"https://conceptkernel.org/ontology/v3.11/recon#text\":\"tdd probe negative\"}}'::jsonb)::text;
ROLLBACK;")
echo "$out" | grep -qi "vacuous\|no SHACL target" && RED "roundtrip blocked by the #134 vacuity signature — retest when the engine fix lands"
echo "$out" | grep -q 'ADOPT=.*"ok": *true'  || BROKEN "recon Adoption did not seal: $out"
echo "$out" | grep -q 'CHUNK=.*"ok": *true'  || BROKEN "well-formed Chunk did not seal post-adoption: $out"
echo "$out" | grep -q 'NEG=.*"ok": *false'   || BROKEN "Chunk MISSING section SEALED — the module shape is vacuous: $out"
echo "$out" | grep -qiE 'NEG=.*(section|MinCount)' || BROKEN "negative refusal does not name section/MinCount: $out"
GREEN "spore roundtrip: adoption sealed, Chunk gated by its module shape, negative control refused naming the clause"
