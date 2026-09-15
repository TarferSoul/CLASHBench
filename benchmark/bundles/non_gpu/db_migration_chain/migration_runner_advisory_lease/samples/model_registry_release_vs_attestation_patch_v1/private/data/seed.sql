CREATE TABLE databasechangeloglock (
  id integer PRIMARY KEY,
  locked boolean NOT NULL,
  lockgranted timestamptz,
  lockedby text,
  owner_client_pid integer
);
INSERT INTO databasechangeloglock VALUES (1,false,NULL,NULL,NULL);
CREATE TABLE databasechangelog (
  id text PRIMARY KEY,
  author text NOT NULL,
  filename text NOT NULL,
  dateexecuted timestamptz NOT NULL,
  orderexecuted integer UNIQUE NOT NULL,
  exectype text NOT NULL,
  md5sum text NOT NULL,
  description text NOT NULL
);
CREATE TABLE model_artifact (
  artifact_id integer PRIMARY KEY,
  model_name text NOT NULL,
  model_version text NOT NULL,
  object_uri text NOT NULL,
  signature_digest text
);
INSERT INTO model_artifact
SELECT g,'model-'||lpad(((g-1)%18+1)::text,2,'0'),'v'||((g-1)%5+1),
       's3://registry/artifacts/'||g,CASE WHEN g%4=0 THEN NULL ELSE md5('sig-'||g) END
FROM generate_series(1,180) g;
CREATE TABLE release_state (
  namespace text PRIMARY KEY,
  status text NOT NULL,
  client_pid integer NOT NULL,
  backend_pid integer NOT NULL,
  owner_token text NOT NULL,
  current_changeset text NOT NULL,
  rows_validated integer NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE migration_audit (
  audit_id bigserial PRIMARY KEY,
  command text NOT NULL,
  changeset_id text NOT NULL,
  acquired_lock boolean NOT NULL,
  backend_pid integer NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO databasechangelog(id,author,filename,dateexecuted,orderexecuted,exectype,md5sum,description)
VALUES ('mr-20260804-100','ml-platform','changelog/baseline.xml',clock_timestamp(),100,'EXECUTED','9:baseline100','model registry baseline');
