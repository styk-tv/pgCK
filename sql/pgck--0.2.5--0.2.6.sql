-- pgck 0.2.5 -> 0.2.6 — CI-A-1: Track A ship-it (SPEC.ROADMAP.v3.9.CHECKLIST index 21).
--
-- Make ck_participant LOGIN so a connection/agent can actually BE it — the exact v3.9
-- §7 threat model: "an agent that obtains database credentials and connects via psql
-- (the F-H failure) can execute ckp.dispatch and nothing else." With LOGIN, the
-- canonical sidecar harness (sql/test/s14_ci_a1_sidecar.sh) demonstrates the §7 exit
-- over a REAL connection (not SET ROLE).
--
-- Auth posture: ck_participant carries NO password here, so remote scram-sha-256 login
-- is impossible; local trust (dev/sidecar) or a deployment-set credential / gateway-
-- proxied connection is how a real agent becomes ck_participant in production. This
-- migration grants the LOGIN *capability* only — the capability set stays { ckp.dispatch }.

ALTER ROLE ck_participant LOGIN;

COMMENT ON ROLE ck_participant IS
  'The only role connections/agents receive; holds EXACTLY EXECUTE ckp.dispatch (CI-A-2). '
  'LOGIN so it can be connected-as (v3.9 §7 threat model); no password here — auth is '
  'gateway/pg_hba-mediated. CKP v3.9 §7 / CI-A-1 (Track A flip: dispatch is the only door).';
