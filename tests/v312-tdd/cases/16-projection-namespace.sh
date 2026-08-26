#!/usr/bin/env bash
# THE PROJECTION RESIDUE (rescan-corrected form of the former alpha-vacuous case):
# task.create on a board-declaring project seals LAWFULLY — M4 = the project's own
# board/shape/Task, measured — but ckp.project_links builds its link TTL typed
# core#Task/core#Goal, IRIs NO surface declares, so its composed-surface gate
# selects ZERO focus nodes and passes silently: a second gate that can only ever
# be judged by nothing. Predicted RED until the projection types link triples in
# the instance's OWN declared namespace (or retires). GREEN = the mismatch closed.
# Deliberately deferred from 0.4.82: changing projection semantics mid-release
# would touch the oci-germination bundle agreements.
source "$(dirname "$0")/../lib.sh"
out=$(Q "SELECT 'CORE_TASK_DECLARED=' || count(*) FROM pgrdf.sparql(
  format('SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/ns/shacl#targetClass> <https://conceptkernel.org/ontology/v3.11/core#Task> } }',
         pgrdf.graph_iri(ckp._composed_shapes('demo'))));
SELECT 'BOARD_TASK_DECLARED=' || count(*) FROM pgrdf.sparql(
  format('SELECT ?s WHERE { GRAPH <%s> { ?s <http://www.w3.org/ns/shacl#targetClass> <urn:ckp:board/Task> } }',
         pgrdf.graph_iri(ckp._composed_shapes('demo'))));
SELECT 'PROJECTION_TYPES_CORE=' || count(*) FROM pg_proc
  WHERE proname='project_links' AND prosrc LIKE '%a ckp:Task%';")
core_t="$(echo "$out" | sed -n 's/^CORE_TASK_DECLARED=//p')"
board_t="$(echo "$out" | sed -n 's/^BOARD_TASK_DECLARED=//p')"
proj="$(echo "$out" | sed -n 's/^PROJECTION_TYPES_CORE=//p')"
[ -n "$core_t" ] && [ -n "$board_t" ] && [ -n "$proj" ] || BROKEN "probe failed: $out"
[ "$board_t" -ge 1 ] || BROKEN "board/Task no longer shaped on demo — the fixture moved: $out"
[ "$core_t" -ge 1 ] && BROKEN "core#Task became a declared target — the root grew a Task?! $out"
if [ "$proj" = "0" ]; then
  GREEN "the projection no longer types core#Task — the namespace mismatch is closed (or the projection retired)"
fi
RED "project_links still types core#Task (declared nowhere; board/Task is the law that judges the seal) — its gate is zero-focus, a silent second pass"
