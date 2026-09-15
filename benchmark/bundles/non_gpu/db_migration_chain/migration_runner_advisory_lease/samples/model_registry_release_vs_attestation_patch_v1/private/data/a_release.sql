\set ON_ERROR_STOP on
SET application_name = 'model-registry-metadata-release';
UPDATE databasechangeloglock
SET locked=true,lockgranted=clock_timestamp(),lockedby='model-registry-release:' || :'client_pid',owner_client_pid=:client_pid
WHERE id=1 AND NOT locked;
SELECT 1 / CASE WHEN locked AND owner_client_pid=:client_pid THEN 1 ELSE 0 END FROM databasechangeloglock WHERE id=1;
INSERT INTO release_state(namespace,status,client_pid,backend_pid,owner_token,current_changeset,rows_validated)
VALUES ('model_registry','running',:client_pid,pg_backend_pid(),'model-registry-release:' || :'client_pid','lease_acquired',0)
ON CONFLICT (namespace) DO UPDATE SET status='running',client_pid=:client_pid,backend_pid=pg_backend_pid(),owner_token='model-registry-release:' || :'client_pid',current_changeset='lease_acquired',rows_validated=0,started_at=clock_timestamp(),updated_at=clock_timestamp();

SELECT pg_sleep(:step_sleep);
CREATE TABLE model_lineage_edge (
  parent_artifact_id integer NOT NULL REFERENCES model_artifact(artifact_id),
  child_artifact_id integer NOT NULL REFERENCES model_artifact(artifact_id),
  relation text NOT NULL,
  PRIMARY KEY(parent_artifact_id,child_artifact_id)
);
INSERT INTO model_lineage_edge SELECT g,g+1,'fine_tuned_from' FROM generate_series(1,60) g;
INSERT INTO databasechangelog VALUES ('mr-20260804-101','ml-platform','changelog/model-lineage.xml',clock_timestamp(),101,'EXECUTED','9:lineage101','create model lineage edges');
UPDATE release_state SET current_changeset='mr-20260804-101',rows_validated=60,updated_at=clock_timestamp() WHERE namespace='model_registry';

SELECT pg_sleep(:step_sleep);
ALTER TABLE model_artifact ADD COLUMN lineage_digest text;
UPDATE model_artifact SET lineage_digest=md5(model_name||':'||model_version||':'||object_uri) WHERE artifact_id<=60;
INSERT INTO databasechangelog VALUES ('mr-20260804-102','ml-platform','changelog/lineage-digest.xml',clock_timestamp(),102,'EXECUTED','9:digest102','add lineage digest');
UPDATE release_state SET current_changeset='mr-20260804-102',rows_validated=(SELECT count(*) FROM model_artifact WHERE lineage_digest IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='model_registry';

SELECT pg_sleep(:step_sleep);
UPDATE model_artifact SET lineage_digest=md5(model_name||':'||model_version||':'||object_uri) WHERE lineage_digest IS NULL;
INSERT INTO databasechangelog VALUES ('mr-20260804-103','ml-platform','changelog/lineage-backfill.xml',clock_timestamp(),103,'EXECUTED','9:backfill103','backfill lineage digests');
UPDATE release_state SET current_changeset='mr-20260804-103',rows_validated=(SELECT count(*) FROM model_artifact WHERE lineage_digest IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='model_registry';

SELECT pg_sleep(:step_sleep);
CREATE TABLE artifact_policy (
  policy_name text PRIMARY KEY,
  minimum_signatures integer NOT NULL,
  require_lineage boolean NOT NULL
);
INSERT INTO artifact_policy VALUES ('production',2,true),('staging',1,true);
INSERT INTO databasechangelog VALUES ('mr-20260804-104','ml-platform','changelog/artifact-policy.xml',clock_timestamp(),104,'EXECUTED','9:policy104','create artifact policy metadata');
UPDATE release_state SET current_changeset='mr-20260804-104',rows_validated=(SELECT count(*) FROM model_artifact WHERE lineage_digest IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='model_registry';

SELECT pg_sleep(:step_sleep);
CREATE INDEX model_artifact_lineage_digest_idx ON model_artifact(lineage_digest);
INSERT INTO databasechangelog VALUES ('mr-20260804-105','ml-platform','changelog/lineage-index.xml',clock_timestamp(),105,'EXECUTED','9:index105','index and validate lineage digests');
UPDATE release_state SET status='completed',current_changeset='mr-20260804-105',rows_validated=(SELECT count(*) FROM model_artifact WHERE lineage_digest IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='model_registry';
UPDATE databasechangeloglock SET locked=false,lockgranted=NULL,lockedby=NULL,owner_client_pid=NULL WHERE id=1 AND owner_client_pid=:client_pid;
