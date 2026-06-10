-- s24_ci_d6_governance_ontology.sql — CI-D-6 (SPEC.ROADMAP.v3.9.CHECKLIST index 11).
--
-- The governance type-plane ontology forward-ports (v3.9 §9). Confirms: ckp:Proposal / ckp:Vote
-- / ckp:Grant classes load into the core graph; a conformant Proposal and Vote validate against
-- their shapes; an out-of-enum proposalState is rejected (the type plane governs itself).
--
-- Run (booted by the smoke): psql … < s24_ci_d6_governance_ontology.sql

\set ON_ERROR_STOP 1

-- (a) the governance classes are declared in the loaded core ontology.
DO $$
DECLARE v_ask text;
BEGIN
  SELECT COALESCE(j->>'_ask', j->>'boolean') INTO v_ask FROM pgrdf.sparql(
    'PREFIX ckp: <https://conceptkernel.org/ontology/v3.8/core#>
     PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
     ASK FROM <urn:ckp:core>
     WHERE { ckp:Proposal a rdfs:Class . ckp:Vote a rdfs:Class . ckp:Grant a rdfs:Class . }') j LIMIT 1;
  IF COALESCE(v_ask, 'false') <> 'true' THEN
    RAISE EXCEPTION 's24 FAIL: governance classes not declared in core (ask=%)', v_ask;
  END IF;
END $$;

-- (b) a conformant Proposal validates against ProposalShape.
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
<urn:ckp:prop:s24-ok> a ckp:Proposal ;
  ckp:about <urn:ckp:demo/kernel/board> ;
  ckp:proposalState "pending" ;
  ckp:requiresQuorum "2"^^xsd:integer .';
BEGIN
  IF NOT ckp.validate(ttl, v_core) THEN RAISE EXCEPTION 's24 FAIL: conformant Proposal did NOT validate'; END IF;
END $$;

-- (c) a Proposal with an out-of-enum proposalState is REJECTED.
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:prop:s24-bad> a ckp:Proposal ;
  ckp:about <urn:ckp:demo/kernel/board> ; ckp:proposalState "bogus" .';
BEGIN
  IF ckp.validate(ttl, v_core) THEN RAISE EXCEPTION 's24 FAIL: out-of-enum proposalState wrongly conformed'; END IF;
END $$;

-- (d) a conformant Vote validates against VoteShape.
DO $$
DECLARE
  v_core int := (SELECT v::int FROM ckp.config WHERE k='core_graph_id');
  ttl text := '@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
<urn:ckp:vote:s24> a ckp:Vote ; ckp:about <urn:ckp:prop:s24-ok> ; ckp:voteValue "approve" .';
BEGIN
  IF NOT ckp.validate(ttl, v_core) THEN RAISE EXCEPTION 's24 FAIL: conformant Vote did NOT validate'; END IF;
END $$;

\echo s24_ci_d6_governance_ontology: PASS
