\set ON_ERROR_STOP on
SET application_name = 'observability-rollup-release';
SELECT pg_advisory_lock(820260804);
INSERT INTO release_state(namespace,status,client_pid,backend_pid,lease_key,current_version,rows_validated)
VALUES ('observability_catalog','running',:client_pid,pg_backend_pid(),820260804,'lease_acquired',0)
ON CONFLICT (namespace) DO UPDATE SET status='running',client_pid=:client_pid,
 backend_pid=pg_backend_pid(),lease_key=820260804,current_version='lease_acquired',
 rows_validated=0,started_at=clock_timestamp(),updated_at=clock_timestamp();

SELECT pg_sleep(:step_sleep);
CREATE TABLE telemetry_rollup_window (
  window_seconds integer PRIMARY KEY,
  resolution_name text UNIQUE NOT NULL,
  max_retention_days integer NOT NULL
);
INSERT INTO telemetry_rollup_window VALUES (60,'one_minute',30),(300,'five_minute',90),(3600,'one_hour',365);
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_101','create telemetry rollup windows','sha256:telemetry-rollup-101',current_user,true);
UPDATE release_state SET current_version='V20260804_101',rows_validated=3,updated_at=clock_timestamp() WHERE namespace='observability_catalog';

SELECT pg_sleep(:step_sleep);
ALTER TABLE telemetry_series ADD COLUMN storage_tier text;
UPDATE telemetry_series SET storage_tier=CASE WHEN retention_days>=35 THEN 'archive' ELSE 'warm' END WHERE series_id<=80;
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_102','add telemetry storage tier','sha256:telemetry-tier-102',current_user,true);
UPDATE release_state SET current_version='V20260804_102',rows_validated=(SELECT count(*) FROM telemetry_series WHERE storage_tier IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='observability_catalog';

SELECT pg_sleep(:step_sleep);
UPDATE telemetry_series SET storage_tier=CASE WHEN retention_days>=35 THEN 'archive' ELSE 'warm' END WHERE storage_tier IS NULL;
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_103','backfill telemetry storage tiers','sha256:telemetry-tier-backfill-103',current_user,true);
UPDATE release_state SET current_version='V20260804_103',rows_validated=(SELECT count(*) FROM telemetry_series WHERE storage_tier IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='observability_catalog';

SELECT pg_sleep(:step_sleep);
CREATE INDEX telemetry_series_retention_tier_idx ON telemetry_series(storage_tier,retention_days);
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_104','index retention tier lookup','sha256:telemetry-tier-index-104',current_user,true);
UPDATE release_state SET current_version='V20260804_104',rows_validated=(SELECT count(*) FROM telemetry_series WHERE storage_tier IS NOT NULL),updated_at=clock_timestamp() WHERE namespace='observability_catalog';

SELECT pg_sleep(:step_sleep);
CREATE TABLE telemetry_release_validation (
  release_version text PRIMARY KEY,
  series_checked integer NOT NULL,
  invalid_series integer NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO telemetry_release_validation
SELECT 'V20260804_105',count(*),count(*) FILTER (WHERE storage_tier IS NULL) FROM telemetry_series;
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_105','validate rollup release catalog','sha256:telemetry-validate-105',current_user,true);
UPDATE release_state SET status='completed',current_version='V20260804_105',rows_validated=(SELECT count(*) FROM telemetry_series),updated_at=clock_timestamp() WHERE namespace='observability_catalog';
SELECT pg_advisory_unlock(820260804);
