#!/usr/bin/env bash
# HANDOVER B1 precondition: our SQL fd1 == the engine's fd1, same graph. Measure.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT (ckp._structural_digest(pgrdf.graph_id('urn:ckp:core')) =
               pgrdf.structural_digest(pgrdf.graph_id('urn:ckp:core')))::text;")
case "$out" in
  *true*)  GREEN "byte-for-byte agreement on urn:ckp:core — delegation (B1) is safe" ;;
  *false*) RED "implementations disagree — B1 blocked; file before delegating" ;;
  *)       BROKEN "could not compare: $out" ;;
esac
