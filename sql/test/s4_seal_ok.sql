\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
SELECT length(ckp.seal('i-greet-1','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Ada"}'::jsonb))=64 AS sha_ok;
SELECT count(*)=1 AS inst FROM ckp.instances WHERE id='i-greet-1';
SELECT count(*)=1 AS led  FROM ckp.ledger    WHERE instance_id='i-greet-1';
SELECT count(*)=1 AS prf  FROM ckp.proof     WHERE about='i-greet-1';
