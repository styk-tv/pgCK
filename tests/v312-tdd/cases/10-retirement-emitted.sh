#!/usr/bin/env bash
# RC2 widening: instance.retire EMITS retiredAtEpoch to the read plane. Predicted RED.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT count(*) FROM pgrdf.sparql(
 'SELECT ?s WHERE { ?s <https://conceptkernel.org/ontology/v3.11/core#retiredAtEpoch> ?e }');")
case "$out" in
  0) RED "0 retiredAtEpoch quads anywhere — retirement is a row state the read plane cannot see" ;;
  [1-9]*) GREEN "$out retirement marker(s) on the read plane — the widening stopped being decorative" ;;
  *) BROKEN "query failed: $out" ;;
esac
