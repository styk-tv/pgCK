#!/usr/bin/env bash
# R-F: a Signal with polarity outside the enum is REFUSED by the RC2 surface.
# GREEN-able today: validate works without the seal path.
source "$(dirname "$0")/../lib.sh"
out=$(Q "DO \$\$ DECLARE g bigint; d bigint; r jsonb; BEGIN
  g := pgrdf.add_graph('urn:tdd:v312-core');
  IF pgrdf.count_quads(g) = 0 THEN
    PERFORM pgrdf.parse_turtle(pg_read_file('/ontology/v3.12/core.ttl'), g); END IF;
  d := pgrdf.add_graph('urn:tdd:v312-sig');
  PERFORM pgrdf.clear_graph(d);
  PERFORM pgrdf.parse_turtle('<urn:tdd:sig1> a <https://conceptkernel.org/ontology/v3.11/core#Signal> ;
    <https://conceptkernel.org/ontology/v3.11/core#signalPolarity> \"bogus\" .', d);
  r := pgrdf.validate(d, g);
  RAISE NOTICE 'conforms=% paths=%', r->>'conforms',
    (SELECT string_agg(DISTINCT x->>'resultPath', ',') FROM jsonb_array_elements(COALESCE(r->'results','[]'::jsonb)) x);
END \$\$;")
echo "$out" | grep -q "conforms=false" || BROKEN "bogus polarity was NOT refused — the enum gate is vacuous: $out"
echo "$out" | grep -qi "signalPolarity" || BROKEN "refusal does not name signalPolarity: $out"
GREEN "bogus polarity refused, path named — the score loop's admission floor holds"
