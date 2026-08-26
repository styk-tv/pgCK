#!/usr/bin/env bash
# T-NULL floor: absent graph refuses 42704; empty graph still answers. GREEN expected.
source "$(dirname "$0")/../lib.sh"
out=$(Q "DO \$\$ BEGIN PERFORM pgrdf.graph_digest(999999999); RAISE NOTICE 'NO-REFUSAL';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'code=%', SQLSTATE; END \$\$;")
echo "$out" | grep -q "NO-REFUSAL" && BROKEN "absent graph digested instead of refusing"
echo "$out" | grep -q "code=42704" || BROKEN "absent-graph refusal is not 42704: $out"
GREEN "absent refuses 42704 — the sha256('') era is over"
