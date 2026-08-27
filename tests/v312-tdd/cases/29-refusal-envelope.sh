#!/usr/bin/env bash
# THE ENVELOPE IS ONE LAW (cklib PASS-2 ISSUE-6 / HANDOVER B7): the SAME refusal
# class must ship the same envelope from every construction site — refused:true +
# a typed sqlstate, pgck's own E0 discipline arriving at its wire envelope.
# Measured baseline: instance.link ships {refused:true}; instance.create ships the
# same type_must_be_iri WITHOUT it. Predicted RED until the refusal registry +
# door normalizer land. GREEN = both sites refusal-flagged AND sqlstate-typed.
source "$(dirname "$0")/../lib.sh"
out=$(Q "BEGIN;
SELECT set_config('ckp.project','demo',true);
SELECT set_config('ckp.requester','svc:v312-tdd',true);
SELECT 'CREATE='||ckp.dispatch('instance.create','{\"type\":\"NotAnIri\",\"title\":\"probe\"}'::jsonb)::text;
SELECT 'LINK='||ckp.dispatch('instance.link','{\"source\":\"a\",\"predicate\":\"urn:p\",\"target\":\"b\",\"type\":\"NotAnIri\"}'::jsonb)::text;
ROLLBACK;")
create=$(echo "$out" | grep '^CREATE=');  link=$(echo "$out" | grep '^LINK=')
[ -n "$create" ] && [ -n "$link" ] || BROKEN "probe replies unreadable: $out"
echo "$create" | grep -q '"ok": *false' || BROKEN "instance.create {type:NotAnIri} did not refuse at all: $create"
c_ref=0; l_ref=0
echo "$create" | grep -q '"refused": *true' && c_ref=1
echo "$link"   | grep -q '"refused": *true' && l_ref=1
if [ "$c_ref" = 1 ] && [ "$l_ref" = 1 ]; then
  if echo "$create" | grep -q '"sqlstate"'; then
    GREEN "one envelope law: both sites refuse with refused:true and a typed sqlstate"
  fi
  RED "refused:true is now uniform but the refusal carries no sqlstate — the E0 half is missing"
fi
[ "$c_ref" = 0 ] && [ "$l_ref" = 1 ] \
  && RED "the SAME refusal ships {refused:true} from instance.link and bare from instance.create — envelope inconsistent between sites (ISSUE-6)"
[ "$c_ref" = 0 ] && [ "$l_ref" = 0 ] \
  && RED "no construction site marks the refusal — consumers cannot structurally tell refusal from fault"
BROKEN "unexpected envelope combination: $out"
