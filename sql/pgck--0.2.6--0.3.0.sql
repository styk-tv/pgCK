-- pgck 0.2.6 -> 0.3.0 — "Critical Isolation Alpha": the web2 verb surface UNDER the floor.
--
-- The intermediary release (maintainer, 2026-06-10): pgCK updates first; CK.Lib.Js then
-- syncs (strips its RDF); web2 confirms with the new client. For web2 to KEEP WORKING on
-- the floored substrate, its existing verb dispatch must be (a) part of the governed
-- extension and (b) reachable by ck_participant through the seal floor — NOT the orphan
-- sql/dispatch.sql that was never loaded.
--
-- sql/dispatch.sql is wired into the extension just before this migration (src/lib.rs,
-- name = pgck_web2_dispatch). It defines ckp._slug / ckp._envelope / ckp._query and the
-- 2-arg ckp.dispatch(text, jsonb) — the full web2 verb set (task.create/update,
-- snapshot.board/bodies, edge.create, notify, kernel.create, instances.*, instance.get/
-- verify, provenance, affordances, kernels.list, participant.join). This migration FLOORS
-- that surface:
--   * the web2 ckp.dispatch(text,jsonb) becomes SECURITY DEFINER owned by ck_substrate,
--     granted to ck_participant (so a connection holding only dispatch drives web2);
--   * the helpers + every ckp function are REVOKEd from PUBLIC (ADP is unreliable inside
--     CREATE EXTENSION), ck_substrate keeps EXECUTE.
--
-- The four-tuple typed dispatch (CI-A-2 shell) coexists as the v3.9 forward door; CI-B
-- makes it the registry-backed ingress and retires this 2-arg path. JWT identity flows
-- exactly as today (transitional GUC).
--
-- Test: sql/test/s15_alpha_web2_verbs.sql.

-- Floor every ckp function from PUBLIC (catches the freshly-loaded web2 dispatch + helpers).
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ckp FROM PUBLIC;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA ckp TO ck_substrate;

-- The web2 dispatch is a SECURITY DEFINER door owned by ck_substrate (so it reaches the
-- seal floor + pgrdf as the Ring-1 owner), granted to the one participant capability.
ALTER FUNCTION ckp.dispatch(text, jsonb) OWNER TO ck_substrate;
ALTER FUNCTION ckp.dispatch(text, jsonb)
  SECURITY DEFINER SET search_path = ckp, public, pg_temp;
GRANT EXECUTE ON FUNCTION ckp.dispatch(text, jsonb) TO ck_participant;

COMMENT ON FUNCTION ckp.dispatch(text, jsonb) IS
  'Critical Isolation Alpha (v0.3.0): the web2 verb dispatch, FLOORED. SECURITY DEFINER as '
  'ck_substrate; granted to ck_participant. web2 keeps working on the isolated substrate. '
  'The v3.9 four-tuple typed dispatch (CI-B) supersedes this 2-arg path.';
