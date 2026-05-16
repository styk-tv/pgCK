\set ON_ERROR_STOP 1
SELECT set_config('ckp.project','demo',false);
SELECT set_config('ckp.identity_key', md5('demo'), false);
CALL ckp.bootstrap_kernel();
SELECT ckp.seal('i-v-1','{"type":"urn:ckp:kernel#Greeting","urn:ckp:kernel#name":"Bo"}'::jsonb) IS NOT NULL AS sealed;
SELECT ckp.verify('i-v-1')=true AS clean;
UPDATE ckp.instances SET body=body||'{"x":1}'::jsonb WHERE id='i-v-1';
SELECT ckp.verify('i-v-1')=false AS tampered;
