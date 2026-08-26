#!/usr/bin/env bash
# E0 floor: engine refusals carry typed SQLSTATEs (pgRDF 0.6.34). GREEN expected.
source "$(dirname "$0")/../lib.sh"
out=$(Q "DO \$\$ BEGIN PERFORM pgrdf.sparql('SELECT * WHERE { SERVICE <http://x> { ?s ?p ?o } }');
  RAISE NOTICE 'NO-REFUSAL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'code=% msg=%', SQLSTATE, left(SQLERRM,60); END \$\$;")
echo "$out" | grep -q "NO-REFUSAL" && BROKEN "SERVICE query did not refuse at all"
echo "$out" | grep -q "code=0A000" || BROKEN "SERVICE refusal is not 0A000: $out"
echo "$out" | grep -qi "SERVICE" || BROKEN "refusal does not name the construct: $out"
GREEN "0A000 with the construct named in prose — E0 live"
