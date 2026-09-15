\set ON_ERROR_STOP on
\connect release_catalog

SET ROLE release_api;

CREATE TABLE package_metadata (
  package_id integer PRIMARY KEY,
  package_name text NOT NULL UNIQUE,
  ecosystem text NOT NULL,
  owner_team text NOT NULL,
  criticality integer NOT NULL CHECK (criticality BETWEEN 1 AND 5)
);

CREATE TABLE staged_release_events (
  event_id bigint PRIMARY KEY,
  package_id integer NOT NULL REFERENCES package_metadata(package_id),
  version text NOT NULL,
  source_sha text NOT NULL,
  artifact_path text NOT NULL,
  download_count integer NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processed')),
  staged_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX staged_release_events_pending_idx
  ON staged_release_events(status, event_id);

CREATE TABLE release_catalog (
  event_id bigint PRIMARY KEY REFERENCES staged_release_events(event_id),
  package_id integer NOT NULL REFERENCES package_metadata(package_id),
  package_name text NOT NULL,
  version text NOT NULL,
  ecosystem text NOT NULL,
  owner_team text NOT NULL,
  artifact_digest text NOT NULL,
  normalized boolean NOT NULL DEFAULT true,
  download_count integer NOT NULL,
  replica_name text NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX release_catalog_package_idx
  ON release_catalog(package_id, version);

CREATE TABLE replica_progress (
  replica_name text PRIMARY KEY,
  health_token text NOT NULL,
  processed_events bigint NOT NULL DEFAULT 0,
  last_event_id bigint,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE release_readiness (
  id integer PRIMARY KEY DEFAULT 1,
  service_generation text NOT NULL,
  replica_count integer NOT NULL,
  catalog_rows bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (id = 1)
);

INSERT INTO package_metadata(package_id, package_name, ecosystem, owner_team, criticality)
SELECT package_id,
       'pkg-' || to_char(package_id, 'FM0000'),
       (ARRAY['python', 'go', 'node', 'rust'])[1 + (package_id % 4)],
       (ARRAY['platform', 'runtime', 'security', 'data'])[1 + (package_id % 4)],
       1 + (package_id % 5)
FROM generate_series(1, 480) AS package_id;

INSERT INTO staged_release_events(
  event_id, package_id, version, source_sha, artifact_path, download_count, status
)
SELECT event_id,
       1 + (event_id % 480),
       format('%s.%s.%s', 1 + (event_id % 7), event_id % 19, event_id % 29),
       md5('source:' || event_id::text),
       '/artifacts/' || md5('artifact:' || event_id::text) || '.tar.gz',
       1000 + (event_id % 90000),
       CASE WHEN event_id <= 600 THEN 'processed' ELSE 'pending' END
FROM generate_series(1, 9000) AS event_id;

INSERT INTO release_catalog(
  event_id, package_id, package_name, version, ecosystem, owner_team,
  artifact_digest, download_count, replica_name
)
SELECT e.event_id, e.package_id, p.package_name, e.version, p.ecosystem, p.owner_team,
       md5(e.source_sha || ':' || e.artifact_path || ':' || p.package_name),
       e.download_count,
       'seed_loader'
FROM staged_release_events e
JOIN package_metadata p ON p.package_id = e.package_id
WHERE e.status = 'processed';

INSERT INTO replica_progress(replica_name, health_token)
SELECT 'release_catalog_replica_' || replica_id,
       'release_catalog_api_token_20260726_v1'
FROM generate_series(0, 3) AS replica_id;

INSERT INTO release_readiness(id, service_generation, replica_count, catalog_rows)
VALUES (
  1,
  'release_catalog_api_generation_v1',
  4,
  (SELECT count(*) FROM release_catalog)
);

RESET ROLE;

GRANT CONNECT ON DATABASE release_catalog TO contract_tester;
GRANT USAGE ON SCHEMA public TO contract_tester;
GRANT SELECT ON package_metadata, staged_release_events, release_catalog,
  replica_progress, release_readiness TO contract_tester;
