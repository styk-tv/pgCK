#!/usr/bin/env bash
# GOVERNANCE reads the record (VRS R-D / PASS-1 F-A): a Proposal whose about names
# ANOTHER kernel must land there or refuse — never silently redirect into the acting
# kernel. Predicted RED. One txn; measured payload contract.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
DO \$\$ DECLARE p jsonb; pid text; a jsonb; nb int; na int; BEGIN
  PERFORM ckp.dispatch('kernel.germinate','{\"project\":\"tdd7a\",\"projectKind\":\"personal\",\"label\":\"probe A\"}'::jsonb);
  PERFORM ckp.dispatch('kernel.germinate','{\"project\":\"tdd7b\",\"projectKind\":\"personal\",\"label\":\"probe B\"}'::jsonb);
  PERFORM set_config('ckp.project','tdd7a',true);
  SELECT count(*) INTO nb FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:tdd7b/kernel/ck> { ?s ?p ?o } }');
  p := ckp.dispatch('kernel.propose_change','{\"op\":\"add_class\",\"about\":\"urn:ckp:tdd7b/kernel/ck\",\"name\":\"Tdd7Probe\",\"detail\":{\"name\":\"Tdd7Probe\"}}'::jsonb);
  pid := p->>'proposal_iri';
  IF pid IS NULL THEN RAISE NOTICE 'PROP_FAIL=%', left(p::text,140); RETURN; END IF;
  PERFORM ckp.dispatch('kernel.vote', jsonb_build_object('about',pid,'value','approve'));
  a := ckp.dispatch('kernel.apply', jsonb_build_object('about',pid));
  SELECT count(*) INTO na FROM pgrdf.sparql('SELECT ?s WHERE { GRAPH <urn:ckp:tdd7b/kernel/ck> { ?s ?p ?o } }');
  RAISE NOTICE 'APPLY_OK=% B_BEFORE=% B_AFTER=%', a->>'ok', nb, na;
END \$\$;
ROLLBACK;")
echo "$out" | grep -q "PROP_FAIL" && BROKEN "propose failed: $out"
line=$(echo "$out" | grep "APPLY_OK=")
echo "$line" | grep -q "APPLY_OK=true" || RED "apply refused before the target question: $out"
nb=$(echo "$line" | sed -n 's/.*B_BEFORE=\([0-9]*\).*/\1/p'); na=$(echo "$line" | sed -n 's/.*B_AFTER=\([0-9]*\).*/\1/p')
[ -n "$nb" ] && [ -n "$na" ] || BROKEN "counts unreadable: $line"
if [ "$na" -gt "$nb" ]; then GREEN "apply landed in the kernel its about names ($nb -> $na) — F-A is fixed"; fi
RED "apply ok while the about-target stayed at $nb quads — silent redirection into the acting kernel (F-A stands)"
