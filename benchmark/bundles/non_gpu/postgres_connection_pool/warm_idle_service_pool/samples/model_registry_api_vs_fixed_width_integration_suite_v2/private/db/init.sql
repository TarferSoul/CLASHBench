\connect model_registry

CREATE SCHEMA registry AUTHORIZATION model_registry_app;

CREATE TABLE registry.models (
  model_name text PRIMARY KEY,
  owner_team text NOT NULL,
  default_stage text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE TABLE registry.model_versions (
  version_id integer PRIMARY KEY,
  model_name text NOT NULL REFERENCES registry.models(model_name),
  semver text NOT NULL,
  artifact_uri text NOT NULL,
  artifact_sha256 text NOT NULL,
  release_candidate boolean NOT NULL,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE TABLE registry.promotion_readiness (
  readiness_id integer PRIMARY KEY,
  version_id integer NOT NULL REFERENCES registry.model_versions(version_id),
  environment text NOT NULL,
  status text NOT NULL,
  checked_at timestamptz NOT NULL,
  notes text NOT NULL
);

CREATE TABLE registry.model_cards (
  card_id integer PRIMARY KEY,
  version_id integer NOT NULL REFERENCES registry.model_versions(version_id),
  section text NOT NULL,
  body_sha256 text NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE registry.registry_audit_events (
  event_id integer PRIMARY KEY,
  model_name text NOT NULL REFERENCES registry.models(model_name),
  event_type text NOT NULL,
  actor text NOT NULL,
  occurred_at timestamptz NOT NULL
);

INSERT INTO registry.models(model_name, owner_team, default_stage, created_at)
VALUES
  ('ranker-prod', 'ranking-platform', 'staging', clock_timestamp() - interval '21 days'),
  ('embedder-search', 'retrieval-platform', 'staging', clock_timestamp() - interval '35 days'),
  ('safety-filter', 'trust-platform', 'canary', clock_timestamp() - interval '42 days');

INSERT INTO registry.model_versions(
  version_id, model_name, semver, artifact_uri, artifact_sha256, release_candidate,
  created_by, created_at
)
SELECT gs, 'ranker-prod', '2.7.' || (gs - 2000),
       's3://local-model-registry/ranker-prod/2.7.' || (gs - 2000),
       md5('ranker-prod:' || gs), gs = 2012,
       'ml-release-bot', clock_timestamp() - ((2013 - gs) || ' days')::interval
FROM generate_series(2001, 2012) AS gs;

INSERT INTO registry.model_versions(
  version_id, model_name, semver, artifact_uri, artifact_sha256, release_candidate,
  created_by, created_at
)
SELECT gs, CASE WHEN gs % 2 = 0 THEN 'embedder-search' ELSE 'safety-filter' END,
       '1.' || (gs % 10) || '.' || (gs % 5),
       's3://local-model-registry/aux/' || gs,
       md5('aux:' || gs), false,
       'registry-sync', clock_timestamp() - ((gs % 17) || ' days')::interval
FROM generate_series(3001, 3040) AS gs;

INSERT INTO registry.promotion_readiness(
  readiness_id, version_id, environment, status, checked_at, notes
)
SELECT row_number() OVER (), 2012, env,
       CASE WHEN env = 'prod-shadow' THEN 'passed' ELSE 'passed' END,
       clock_timestamp() - (row_number() OVER () || ' hours')::interval,
       'automated readiness check for ' || env
FROM (VALUES ('schema'), ('features'), ('latency'), ('rollback'), ('prod-shadow')) AS x(env);

INSERT INTO registry.promotion_readiness(
  readiness_id, version_id, environment, status, checked_at, notes
)
SELECT 100 + row_number() OVER (), version_id, 'schema',
       CASE WHEN version_id % 5 = 0 THEN 'failed' ELSE 'passed' END,
       clock_timestamp() - (version_id % 11 || ' hours')::interval,
       'historical readiness record'
FROM registry.model_versions
WHERE version_id <> 2012;

INSERT INTO registry.model_cards(card_id, version_id, section, body_sha256, updated_at)
SELECT row_number() OVER (), version_id, section,
       md5(version_id::text || ':' || section),
       clock_timestamp() - (version_id % 9 || ' hours')::interval
FROM registry.model_versions
CROSS JOIN (VALUES ('overview'), ('training-data'), ('eval-summary')) AS x(section);

INSERT INTO registry.registry_audit_events(event_id, model_name, event_type, actor, occurred_at)
SELECT row_number() OVER (), model_name,
       CASE WHEN gs % 4 = 0 THEN 'promotion_requested' ELSE 'metadata_refreshed' END,
       'registry-api-' || (gs % 6),
       clock_timestamp() - (gs || ' minutes')::interval
FROM registry.models
CROSS JOIN generate_series(1, 25) AS gs;

GRANT CONNECT ON DATABASE model_registry TO model_registry_app, model_registry_validator;
GRANT USAGE ON SCHEMA registry TO model_registry_app, model_registry_validator;
GRANT SELECT ON ALL TABLES IN SCHEMA registry TO model_registry_app, model_registry_validator;
ALTER DEFAULT PRIVILEGES FOR ROLE model_registry_app IN SCHEMA registry
  GRANT SELECT ON TABLES TO model_registry_validator;
