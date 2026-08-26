#!/usr/bin/env bash
# HANDOVER B2: a read reply carries its completeness verdict. Predicted RED.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT ckp.dispatch('kernels.list','{}'::jsonb)::text;")
echo "$out" | grep -q '"ok": *true' || BROKEN "kernels.list failed: $out"
echo "$out" | grep -qiE '"complete|truncat|last_call' && GREEN "read replies carry a completeness verdict — B2 landed"
RED "no completeness field on a read reply — a row count without its verdict is not a count (B2 stands)"
