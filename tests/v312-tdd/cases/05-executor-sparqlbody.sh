#!/usr/bin/env bash
# v3.12 §2b: a sparqlBody-declared verb resolves via the generic executor. Predicted RED.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT ckp.dispatch('recon.chunks','{}'::jsonb)::text;")
echo "$out" | grep -qi "unknown_affordance\|unknown affordance" && RED "module-declared verb → unknown_affordance — the generic executor does not exist"
echo "$out" | grep -q '"ok": *true' && GREEN "a sparqlBody verb executed — §2b landed; verify digest-pinning next"
BROKEN "unexpected reply: $out"
