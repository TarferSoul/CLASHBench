SET client_min_messages = warning;

CREATE TABLE source_changes (
  event_id integer PRIMARY KEY,
  account_id integer NOT NULL,
  shard_id integer NOT NULL,
  payload jsonb NOT NULL,
  arrived_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE feature_cache (
  account_id integer PRIMARY KEY,
  total_events bigint NOT NULL DEFAULT 0,
  last_event_id integer NOT NULL DEFAULT 0,
  last_payload_hash text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE SEQUENCE feature_update_seq;

CREATE TABLE feature_cache_updates (
  update_id bigint PRIMARY KEY DEFAULT nextval('feature_update_seq'),
  worker_id integer NOT NULL,
  account_id integer NOT NULL,
  source_event_id integer NOT NULL,
  payload_hash text NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE dispatcher_progress (
  worker_id integer PRIMARY KEY,
  generation text NOT NULL,
  batches bigint NOT NULL DEFAULT 0,
  events_total bigint NOT NULL DEFAULT 0,
  last_event_id integer NOT NULL DEFAULT 0,
  heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO source_changes(event_id, account_id, shard_id, payload)
SELECT gs,
       ((gs - 1) % 512) + 1,
       mod(gs, 10),
       jsonb_build_object(
         'source', 'api',
         'plan', mod(gs, 7),
         'score', mod(gs * 31, 997),
         'changed_field', CASE WHEN mod(gs, 3) = 0 THEN 'risk_score' ELSE 'activity_count' END
       )
FROM generate_series(1, 6000) AS gs;

INSERT INTO feature_cache(account_id, total_events, last_event_id, last_payload_hash)
SELECT account_id, 0, 0, md5(account_id::text)
FROM generate_series(1, 512) AS account_id;

INSERT INTO dispatcher_progress(worker_id, generation)
SELECT worker_id, 'feature-cdc-v1'
FROM generate_series(0, 9) AS worker_id;

CREATE INDEX source_changes_shard_event_idx ON source_changes(shard_id, event_id);
CREATE INDEX feature_cache_updates_worker_idx ON feature_cache_updates(worker_id, update_id);

GRANT CONNECT ON DATABASE featuredb TO feature_cdc, pool_regression;
GRANT USAGE ON SCHEMA public TO feature_cdc, pool_regression;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO feature_cdc;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO feature_cdc;
GRANT SELECT ON source_changes, feature_cache, feature_cache_updates, dispatcher_progress TO pool_regression;

