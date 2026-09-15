\set ON_ERROR_STOP on
CREATE TABLE feature_snapshots (
  snapshot_id bigint PRIMARY KEY,
  tenant text NOT NULL,
  model_key text NOT NULL,
  entity_id bigint NOT NULL,
  feature_set text NOT NULL,
  generated_at timestamptz NOT NULL,
  freshness_epoch bigint NOT NULL,
  feature_hash text NOT NULL,
  payload text NOT NULL
);
CREATE TABLE migration_history (
  version text PRIMARY KEY,
  state text NOT NULL CHECK (state IN ('dirty','clean')),
  owner_job_id text NOT NULL,
  owner_backend_pid integer,
  plan_digest text NOT NULL,
  current_step text NOT NULL,
  completed_steps integer NOT NULL,
  expected_steps integer NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  applied_by text NOT NULL
);
CREATE TABLE migration_events (
  event_id bigserial PRIMARY KEY,
  version text NOT NULL,
  job_id text NOT NULL,
  backend_pid integer,
  event_kind text NOT NULL,
  step_name text NOT NULL,
  old_object_oid oid,
  new_object_oid oid,
  plan_digest text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE case_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  expected_rows bigint NOT NULL,
  expected_steps integer NOT NULL,
  dataset_digest text NOT NULL
);
INSERT INTO feature_snapshots
SELECT i, 'tenant-' || i % 257, 'model-' || i % 31, i % 180000,
       'set-' || i % 19,
       timestamptz '2026-01-01 00:00:00+00' + (i % 7000000) * interval '1 second',
       1000000 + i, md5('feature:' || i::text),
       repeat(md5(i::text || ':' || (i % 4093)::text), 4)
FROM generate_series(1, :seed_rows::bigint) AS i;
CREATE INDEX feature_tenant_entity_idx ON feature_snapshots(tenant,entity_id);
CREATE INDEX feature_model_generated_idx ON feature_snapshots(model_key,generated_at DESC);
CREATE INDEX feature_set_freshness_idx ON feature_snapshots(feature_set,freshness_epoch DESC);
CREATE INDEX feature_hash_lookup_idx ON feature_snapshots(feature_hash);
CREATE INDEX feature_payload_fingerprint_idx ON feature_snapshots((md5(payload || snapshot_id::text)));
CREATE INDEX feature_tenant_model_entity_idx ON feature_snapshots(tenant,model_key,entity_id);
INSERT INTO case_config(expected_rows,expected_steps,dataset_digest)
SELECT count(*), :expected_steps::integer,
       md5(count(*)::text || ':' || sum(snapshot_id)::text || ':' || sum(entity_id)::text)
FROM feature_snapshots;
ANALYZE feature_snapshots;
