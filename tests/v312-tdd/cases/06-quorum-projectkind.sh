#!/usr/bin/env bash
# GOVERNANCE reads the record (VRS R-D / SPORE §5.2): apply at quorum 1 on a project
# declared 'shared' must REFUSE naming the clause. Predicted RED: quorum resolves
# COALESCE(...,1) and projectKind is read by nothing — proposer=voter=applier clears.
# Whole chain in ONE txn (payload contract measured on the wire 2026-08-26:
# propose {op,name,detail} → vote/apply {about: proposal_iri}).
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.requester','svc:v312-tdd',true);
DO \$\$ DECLARE g jsonb; p jsonb; pid text; v jsonb; a jsonb; BEGIN
  g := ckp.dispatch('kernel.germinate','{\"project\":\"tdd6\",\"projectKind\":\"shared\",\"label\":\"tdd quorum probe\"}'::jsonb);
  IF (g->>'ok') <> 'true' THEN RAISE NOTICE 'GERM_FAIL=%', left(g::text,140); RETURN; END IF;
  PERFORM set_config('ckp.project','tdd6',true);
  p := ckp.dispatch('kernel.propose_change','{\"op\":\"add_class\",\"name\":\"Tdd6Probe\",\"detail\":{\"name\":\"Tdd6Probe\"}}'::jsonb);
  pid := p->>'proposal_iri';
  IF pid IS NULL THEN RAISE NOTICE 'PROP_FAIL=%', left(p::text,140); RETURN; END IF;
  v := ckp.dispatch('kernel.vote', jsonb_build_object('about',pid,'value','approve'));
  a := ckp.dispatch('kernel.apply', jsonb_build_object('about',pid));
  RAISE NOTICE 'APPLY_OK=% APPLY=%', a->>'ok', left(a::text,180);
END \$\$;
ROLLBACK;")
echo "$out" | grep -q "GERM_FAIL\|PROP_FAIL" && BROKEN "chain broke before the quorum question: $out"
echo "$out" | grep -qiE "APPLY.*quorum|APPLY.*shared" && GREEN "apply at quorum 1 on a shared project REFUSED naming the clause — projectKind is finally read"
echo "$out" | grep -q "APPLY_OK=true" && RED "apply CLEARED at quorum 1, proposer=voter=applier, on a project DECLARED shared — the contract is read by nothing"
BROKEN "apply failed for an unstated reason: $out"
