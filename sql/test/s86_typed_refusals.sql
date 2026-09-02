-- s86_typed_refusals.sql — A REFUSAL A CLASSIFIER CAN KEY ON (0.4.106).
--
-- 89 of 97 refusal sites carried no sqlstate. Now every site types itself:
-- literal refusal codes carry their REGISTERED sqlstate, fault wrappers carry
-- the REAL SQLSTATE of what they caught, and the delegate seam is 0A000. The
-- registry is the one source of truth; a returned code it does not know
-- teaches nothing and fails this gate.
\set ON_ERROR_STOP 1

DO $$
DECLARE untyped int; unregistered int; names text; codes text; r jsonb;
BEGIN
  -- (a) zero untyped sites, measured from the LIVE catalog.
  WITH f AS MATERIALIZED (
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='ckp' AND p.prokind='f'),
  sites AS (
    SELECT f.proname, s.chunk FROM f,
           LATERAL regexp_split_to_table(pg_get_functiondef(f.oid),
                   'jsonb_build_object\(''ok'', false') WITH ORDINALITY AS s(chunk, ord)
     WHERE s.ord > 1)
  SELECT count(*) FILTER (WHERE left(chunk,300) NOT LIKE '%sqlstate%'),
         string_agg(DISTINCT proname, ', ') FILTER (WHERE left(chunk,300) NOT LIKE '%sqlstate%')
    INTO untyped, names FROM sites;
  IF untyped > 0 THEN
    RAISE EXCEPTION 's86 (a) FAIL — % refusal site(s) without sqlstate (in: %)', untyped, names; END IF;
  RAISE NOTICE 's86 (a) PASS — every ok:false construction site types itself';

  -- (b) every returned literal code is REGISTERED.
  WITH f AS MATERIALIZED (
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='ckp' AND p.prokind='f'),
  c AS (SELECT DISTINCT m[1] AS code FROM f,
          LATERAL regexp_matches(pg_get_functiondef(f.oid), '''error'', ''([a-z0-9_]+)''', 'g') m)
  SELECT count(*), string_agg(code, ', ') INTO unregistered, codes
    FROM c WHERE NOT EXISTS (SELECT 1 FROM ckp.refusal_registry rr WHERE rr.code = c.code);
  IF unregistered > 0 THEN
    RAISE EXCEPTION 's86 (b) FAIL — % returned code(s) not in the registry: %', unregistered, codes; END IF;
  RAISE NOTICE 's86 (b) PASS — every returned literal code is registered';

  -- (c) CONTROL: a live refusal agrees with its registry row — the registry
  -- must document what the wire actually says, or it is decoration.
  r := ckp.update_typed(jsonb_build_object('id','s86-never-existed','patch',jsonb_build_object('x',1)));
  IF r->>'error' IS DISTINCT FROM 'unknown_instance' THEN
    RAISE EXCEPTION 's86 (c) FAIL — expected unknown_instance, got %', r->>'error'; END IF;
  IF r->>'sqlstate' IS DISTINCT FROM (SELECT sqlstate FROM ckp.refusal_registry WHERE code='unknown_instance') THEN
    RAISE EXCEPTION 's86 (c) FAIL — live sqlstate % disagrees with the registered one', COALESCE(r->>'sqlstate','none'); END IF;
  RAISE NOTICE 's86 (c) PASS — a live refusal carries exactly the sqlstate its registry row declares (%)', r->>'sqlstate';

  -- (d) CONTROL: a FAULT carries the true SQLSTATE of what was caught, not a
  -- refusal class — the two must stay distinguishable (anything non-XX-class
  -- may be treated as a refusal; a fault must not masquerade as one).
  r := ckp.update_typed(jsonb_build_object('id','s86-never-existed'));
  IF r->>'error' IS DISTINCT FROM 'invalid_patch' OR r->>'sqlstate' IS DISTINCT FROM '22023' THEN
    RAISE EXCEPTION 's86 (d) FAIL — invalid_patch must type 22023, got %/%', r->>'error', COALESCE(r->>'sqlstate','none'); END IF;
  RAISE NOTICE 's86 (d) PASS — refusal classes stay in their registered classes';
END $$;

\echo 's86 PASS — every refusal typed, every code registered, the wire and the registry agree'
