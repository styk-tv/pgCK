#!/usr/bin/env bash
# The flip, proven on the INSTALLED extension: ckp.boot()'s default is the v3.12 root.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT pg_get_functiondef('ckp.boot(text)'::regprocedure);")
echo "$out" | grep -q "/ontology/v3.12/core.ttl" && GREEN "installed boot() defaults to v3.12 FINAL"
echo "$out" | grep -q "/ontology/v3.11/core.ttl" && RED "installed boot() still defaults to v3.11 — the stack predates the flip; rebuild (build-ext + recreate) flips this"
BROKEN "boot() default is neither line: $out"
