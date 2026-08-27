#!/usr/bin/env bash
# THE SEAL-SHOWS-UP-IN-ITS-LIST OBLIGATION (#56 measured as a LOOP, not a count):
# govern add_affordance in (P0-E contract: detail.verb + detail.query) → apply ok →
# the verb must (a) be CALLABLE and (b) APPEAR in the affordances reply's list.
# Predicted RED at (b): apply registers the plan (callable ✓) but seals NO
# ckp:Affordance — capability works while its sealed declaration is absent, so the
# list that should carry it stays []. GREEN when apply seals the Affordance and
# the affordances list carries it (v3.12 §2b / VRS R-C / HANDOVER B5).
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT set_config('ckp.project','demo',true);
DO \$\$ DECLARE p jsonb; pid text; a jsonb; call jsonb; aff jsonb; n int; BEGIN
  p := ckp.dispatch('kernel.propose_change','{\"op\":\"add_affordance\",\"detail\":{
    \"verb\":\"demo.probe.count\",
    \"query\":\"SELECT (COUNT(?s) AS ?n) WHERE { GRAPH <urn:ckp:demo/instances> { ?s ?p ?o } }\"}}'::jsonb);
  pid := p->>'proposal_iri';
  IF pid IS NULL THEN RAISE NOTICE 'PROP_FAIL=%', left(p::text,160); RETURN; END IF;
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about',pid,'value','approve'));
  a := ckp.dispatch('kernel.apply', jsonb_build_object('about',pid));
  RAISE NOTICE 'APPLY_OK=%', a->>'ok';
  call := ckp.dispatch('demo.probe.count','{}'::jsonb);
  RAISE NOTICE 'CALLABLE=%', call->>'ok';
  aff := ckp.dispatch('affordances','{}'::jsonb);
  -- instrument correction 0.4.85: the reply's list key is 'affordances' (B1's
  -- contract since 0.4.51); 'derived' was HANDOVER shorthand, never a key.
  -- ::text on the boolean: RAISE formats bare booleans as t/f, which the
  -- grep below could never match — the instrument hid its own success.
  RAISE NOTICE 'LISTED=%', ((aff->'affordances')::text ~ 'demo.probe.count')::text;
  SELECT count(*) INTO n FROM ckp.instances WHERE body->>'type' LIKE '%core#Affordance';
  RAISE NOTICE 'SEALED_AFFORDANCES=%', n;
END \$\$;
ROLLBACK;")
echo "$out" | grep -q "PROP_FAIL" && BROKEN "propose refused — the P0-E contract moved: $out"
echo "$out" | grep -q "APPLY_OK=true" || BROKEN "apply failed: $out"
echo "$out" | grep -q "CALLABLE=true" || BROKEN "applied verb is NOT callable — worse than #56 (the registration itself broke): $out"
if echo "$out" | grep -q "LISTED=true"; then
  echo "$out" | grep -qE "SEALED_AFFORDANCES=[1-9]" || BROKEN "listed in derived[] yet 0 sealed Affordances — the list invented a fact"
  GREEN "governed verb applied, callable, LISTED, sealed — #56 is closed on this loop"
fi
RED "applied ok + CALLABLE, but ABSENT from the affordances list and $(echo "$out"|grep -o 'SEALED_AFFORDANCES=[0-9]*') — capability without its sealed face; what was governed in does not show up in its own list (#56, the loop form)"
