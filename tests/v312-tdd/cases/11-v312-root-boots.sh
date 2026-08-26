#!/usr/bin/env bash
# R-F admission floor: RC2 loads and carries 30 NodeShapes = 27+3, predicted-then-counted.
source "$(dirname "$0")/../lib.sh"
out=$(Q "DO \$\$ DECLARE g bigint; n int; BEGIN
  g := pgrdf.add_graph('urn:tdd:v312-core');
  PERFORM pgrdf.clear_graph(g);
  PERFORM pgrdf.parse_turtle(pg_read_file('/ontology/v3.12/core.ttl'), g);
  SELECT count(*) INTO n FROM pgrdf.sparql(
    'SELECT ?s WHERE { GRAPH <urn:tdd:v312-core> { ?s a <http://www.w3.org/ns/shacl#NodeShape> } }');
  RAISE NOTICE 'nodeshapes=%', n; END \$\$;")
echo "$out" | grep -q "nodeshapes=30" && GREEN "RC2 loads: 30 NodeShapes = 27+3, as predicted"
echo "$out" | grep -q "nodeshapes=" && BROKEN "RC2 loaded but count is not 30: $out"
BROKEN "RC2 did not load: $out"
