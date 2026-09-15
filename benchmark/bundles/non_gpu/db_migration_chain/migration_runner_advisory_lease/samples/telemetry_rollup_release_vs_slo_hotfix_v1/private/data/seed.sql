CREATE TABLE schema_history (
  installed_rank bigserial PRIMARY KEY,
  version text UNIQUE NOT NULL,
  description text NOT NULL,
  checksum text NOT NULL,
  installed_by text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  success boolean NOT NULL
);
CREATE TABLE telemetry_series (
  series_id integer PRIMARY KEY,
  service_name text NOT NULL,
  sample_period_seconds integer NOT NULL,
  retention_days integer NOT NULL
);
INSERT INTO telemetry_series
SELECT g, 'service-' || lpad(((g-1)%12+1)::text, 2, '0'),
       CASE WHEN g%3=0 THEN 60 ELSE 15 END, 14 + (g%4)*7
FROM generate_series(1, 240) g;
CREATE TABLE release_state (
  namespace text PRIMARY KEY,
  status text NOT NULL,
  client_pid integer NOT NULL,
  backend_pid integer NOT NULL,
  lease_key bigint NOT NULL,
  current_version text NOT NULL,
  rows_validated integer NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE migration_audit (
  audit_id bigserial PRIMARY KEY,
  command text NOT NULL,
  version text NOT NULL,
  acquired_lock boolean NOT NULL,
  backend_pid integer NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_history(version,description,checksum,installed_by,success)
VALUES ('V20260804_100','observability catalog baseline','sha256:telemetry-baseline-100',current_user,true);
