#!/usr/bin/env bash
# RC2→FINAL: the seven constants are LAW WITH TEETH. Three negative controls, each
# aimed at the constraint that earns more than a datatype:
#   (1) weightDissent > 0  — the one sign error that inverts every Score
#   (2) thresholdDiscard > thresholdPromote — the only cross-property invariant
#   (3) positive control, precise: on LAWFUL constant values, no CONSTANT path fires.
#       (KernelShape's structural requirements — epoch/inProject/hasOrgan/label — may
#       fire on a bare candidate; the claim under test is only the constants block.)
source "$(dirname "$0")/../lib.sh"
out=$(Q "DO \$\$ DECLARE g bigint; d bigint; r1 jsonb; r2 jsonb; r3 jsonb; BEGIN
  g := pgrdf.add_graph('urn:tdd:v312-core');
  IF pgrdf.count_quads(g) = 0 THEN
    PERFORM pgrdf.parse_turtle(pg_read_file('/ontology/v3.12/core.ttl'), g); END IF;
  d := pgrdf.add_graph('urn:tdd:v312-kernel');
  PERFORM pgrdf.clear_graph(d);
  PERFORM pgrdf.parse_turtle('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    <urn:tdd:k1> a ckp:Kernel ; ckp:weightDissent 0.5 .', d);
  r1 := pgrdf.validate(d, g);
  PERFORM pgrdf.clear_graph(d);
  PERFORM pgrdf.parse_turtle('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    <urn:tdd:k2> a ckp:Kernel ; ckp:thresholdDiscard 0.9 ; ckp:thresholdPromote 0.1 .', d);
  r2 := pgrdf.validate(d, g);
  PERFORM pgrdf.clear_graph(d);
  PERFORM pgrdf.parse_turtle('@prefix ckp: <https://conceptkernel.org/ontology/v3.11/core#> .
    <urn:tdd:k3> a ckp:Kernel ; ckp:weightDissent -0.8 ; ckp:decayLambda 0.05 ;
      ckp:thresholdDiscard 0.1 ; ckp:thresholdPromote 0.7 .', d);
  r3 := pgrdf.validate(d, g);
  RAISE NOTICE 'dissent_pos=% p1=%', r1->>'conforms', (SELECT string_agg(DISTINCT x->>'resultPath', ',')
    FROM jsonb_array_elements(COALESCE(r1->'results','[]'::jsonb)) x);
  RAISE NOTICE 'inverted_bands=% p2=%', r2->>'conforms', (SELECT string_agg(DISTINCT x->>'resultPath', ',')
    FROM jsonb_array_elements(COALESCE(r2->'results','[]'::jsonb)) x);
  RAISE NOTICE 'lawful_constant_hits=%', (SELECT count(*)
    FROM jsonb_array_elements(COALESCE(r3->'results','[]'::jsonb)) x
    WHERE x->>'resultPath' ~ '(weight|decay|threshold)');
END \$\$;")
echo "$out" | grep -q "dissent_pos=false"          || BROKEN "positive weightDissent was NOT refused — the sign gate is vacuous: $out"
echo "$out" | grep -E -q "p1=.*weightDissent"       || BROKEN "the dissent refusal does not name weightDissent: $out"
echo "$out" | grep -q "inverted_bands=false"        || BROKEN "inverted thresholds were NOT refused — sh:lessThan not enforced: $out"
echo "$out" | grep -E -q "p2=.*threshold"           || BROKEN "the band refusal does not name a threshold path: $out"
echo "$out" | grep -q "lawful_constant_hits=0"      || BROKEN "a LAWFUL constant value fired a constant constraint — over-refusal: $out"
GREEN "sign gate + band invariant refuse naming their paths; lawful values fire nothing — the constants have teeth"
