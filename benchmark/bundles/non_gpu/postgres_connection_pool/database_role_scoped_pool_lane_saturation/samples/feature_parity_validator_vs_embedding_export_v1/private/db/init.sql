\set ON_ERROR_STOP on

CREATE TABLE tenant_feature_scope (
  tenant_id integer PRIMARY KEY,
  shard_id text NOT NULL UNIQUE,
  model_version text NOT NULL,
  enabled boolean NOT NULL DEFAULT true
);

INSERT INTO tenant_feature_scope(tenant_id, shard_id, model_version)
VALUES
  (5101, 'fs-a', 'embedding-feature-v3-20260726'),
  (5102, 'fs-b', 'embedding-feature-v3-20260726'),
  (5103, 'fs-c', 'embedding-feature-v3-20260726'),
  (5104, 'fs-d', 'embedding-feature-v3-20260726'),
  (5105, 'fs-e', 'embedding-feature-v3-20260726');

CREATE TABLE model_version_metadata (
  model_version text PRIMARY KEY,
  feature_name text NOT NULL,
  embedding_dim integer NOT NULL CHECK (embedding_dim > 0),
  training_cutoff date NOT NULL,
  visibility_tag text NOT NULL
);

INSERT INTO model_version_metadata(model_version, feature_name, embedding_dim, training_cutoff, visibility_tag)
VALUES (
  'embedding-feature-v3-20260726',
  'embedding_feature_v3',
  8,
  DATE '2026-07-26',
  'validator-visible'
);

CREATE TABLE embedding_feature_v3 (
  feature_id bigserial PRIMARY KEY,
  tenant_id integer NOT NULL REFERENCES tenant_feature_scope(tenant_id),
  shard_id text NOT NULL,
  model_version text NOT NULL REFERENCES model_version_metadata(model_version),
  entity_id bigint NOT NULL,
  feature_name text NOT NULL DEFAULT 'embedding_feature_v3',
  embedding_vector double precision[] NOT NULL,
  embedding_norm numeric(12, 6) NOT NULL,
  feature_payload jsonb NOT NULL,
  produced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (tenant_id, model_version, entity_id)
);

INSERT INTO embedding_feature_v3(
  tenant_id, shard_id, model_version, entity_id, embedding_vector, embedding_norm, feature_payload
)
SELECT scope.tenant_id,
       scope.shard_id,
       scope.model_version,
       scope.tenant_id * 100000 + ordinal,
       ARRAY[
         ((scope.tenant_id + ordinal * 3) % 97) / 97.0,
         ((scope.tenant_id + ordinal * 5) % 89) / 89.0,
         ((scope.tenant_id + ordinal * 7) % 83) / 83.0,
         ((scope.tenant_id + ordinal * 11) % 79) / 79.0,
         ((scope.tenant_id + ordinal * 13) % 73) / 73.0,
         ((scope.tenant_id + ordinal * 17) % 71) / 71.0,
         ((scope.tenant_id + ordinal * 19) % 67) / 67.0,
         ((scope.tenant_id + ordinal * 23) % 61) / 61.0
       ]::double precision[],
       round((
         ((scope.tenant_id + ordinal * 3) % 97) / 97.0 +
         ((scope.tenant_id + ordinal * 5) % 89) / 89.0 +
         ((scope.tenant_id + ordinal * 7) % 83) / 83.0 +
         ((scope.tenant_id + ordinal * 11) % 79) / 79.0
       )::numeric, 6),
       jsonb_build_object(
         'tenant_id', scope.tenant_id,
         'entity_offset', ordinal,
         'source', 'feature-lab-fixture',
         'quality_bucket', CASE ordinal % 4 WHEN 0 THEN 'gold' WHEN 1 THEN 'silver' WHEN 2 THEN 'bronze' ELSE 'holdout' END
       )
FROM tenant_feature_scope AS scope
CROSS JOIN generate_series(1, 140) AS ordinal;

ALTER TABLE embedding_feature_v3 ENABLE ROW LEVEL SECURITY;

CREATE POLICY feature_validator_visible_rows
ON embedding_feature_v3
FOR SELECT
TO feature_validator
USING (
  tenant_id IN (
    SELECT tenant_id
    FROM tenant_feature_scope
    WHERE enabled AND model_version = embedding_feature_v3.model_version
  )
);

CREATE TABLE feature_snapshot_audit (
  worker_name text PRIMARY KEY,
  partition_id text NOT NULL,
  model_version text NOT NULL,
  completed_checkpoints bigint NOT NULL DEFAULT 0,
  rows_hashed bigint NOT NULL DEFAULT 0,
  bytes_streamed bigint NOT NULL DEFAULT 0,
  last_sha256 text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE feature_lane_control (
  component text PRIMARY KEY,
  generation text NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO feature_lane_control(component, generation)
VALUES ('feature-lab-control', 'feature-lab-20260726-r2');

GRANT USAGE ON SCHEMA public TO feature_validator, feature_observer;
GRANT SELECT ON tenant_feature_scope TO feature_validator;
GRANT SELECT ON model_version_metadata TO feature_validator;
GRANT SELECT ON embedding_feature_v3 TO feature_validator;
GRANT SELECT, INSERT, UPDATE ON feature_snapshot_audit TO feature_validator;
GRANT SELECT ON feature_lane_control TO feature_observer;
