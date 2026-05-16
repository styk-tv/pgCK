\set ON_ERROR_STOP 1
SELECT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
  <urn:ckp:prf:bad> a ckp:Proof ; ckp:about <urn:ckp:i:1> .', 1) = false AS rejects_bad;
SELECT ckp.validate('@prefix ckp: <https://conceptkernel.org/ontology/v3.8/core#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  <urn:ckp:prf:ok> a ckp:Proof ; ckp:about <urn:ckp:i:1> ; ckp:method "ed25519+sha256" ;
  ckp:digest "0000000000000000000000000000000000000000000000000000000000000000" ;
  ckp:verifiedAt "2026-05-16T00:00:00Z"^^xsd:dateTime .', 1) = true AS accepts_good;
