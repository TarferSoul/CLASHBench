CREATE EXTENSION IF NOT EXISTS pgrowlocks;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE tenant_quotas (
  tenant_id text PRIMARY KEY,
  plan_token_limit bigint NOT NULL,
  consumed_tokens bigint NOT NULL,
  credit_tokens bigint NOT NULL DEFAULT 0,
  revision integer NOT NULL,
  last_reconcile_run text,
  last_credit_reason text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE metering_events (
  tenant_id text NOT NULL REFERENCES tenant_quotas(tenant_id),
  meter_window text NOT NULL,
  event_no integer NOT NULL,
  model_family text NOT NULL,
  input_tokens integer NOT NULL,
  output_tokens integer NOT NULL,
  event_digest text NOT NULL,
  PRIMARY KEY (tenant_id, meter_window, event_no)
);

CREATE TABLE quota_reconcile_runs (
  run_id text PRIMARY KEY,
  tenant_id text NOT NULL REFERENCES tenant_quotas(tenant_id),
  meter_window text NOT NULL,
  event_count integer NOT NULL,
  metered_tokens bigint NOT NULL,
  event_digest text NOT NULL,
  committed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE quota_credit_audit (
  id bigserial PRIMARY KEY,
  tenant_id text NOT NULL REFERENCES tenant_quotas(tenant_id),
  revision integer NOT NULL,
  credit_tokens bigint NOT NULL,
  reason text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  actor text NOT NULL DEFAULT current_user,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO tenant_quotas(
  tenant_id, plan_token_limit, consumed_tokens, credit_tokens, revision
) VALUES
  ('tenant-vector-prod-042', 90000000, 43800000, 0, 31),
  ('tenant-control-ops', 1000000, 120000, 0, 4);

INSERT INTO metering_events(
  tenant_id, meter_window, event_no, model_family,
  input_tokens, output_tokens, event_digest
)
SELECT
  'tenant-vector-prod-042',
  '2026-08-04T12:00Z',
  n,
  CASE WHEN n % 3 = 0 THEN 'rerank-v3' ELSE 'embed-v4' END,
  300 + n,
  142,
  encode(digest(format(
    'tenant-vector-prod-042:%s:%s:%s:%s',
    n,
    CASE WHEN n % 3 = 0 THEN 'rerank-v3' ELSE 'embed-v4' END,
    300 + n,
    142
  ), 'sha256'), 'hex')
FROM generate_series(1, 192) AS n;

GRANT CONNECT ON DATABASE feature_quota TO quota_reconciler, quota_operator;
GRANT CONNECT ON DATABASE feature_quota_control TO quota_reconciler, quota_operator;
GRANT USAGE ON SCHEMA public TO quota_reconciler, quota_operator;
GRANT SELECT, UPDATE ON tenant_quotas TO quota_reconciler;
GRANT SELECT ON metering_events TO quota_reconciler;
GRANT INSERT, SELECT ON quota_reconcile_runs TO quota_reconciler;
GRANT SELECT, UPDATE ON tenant_quotas TO quota_operator;
GRANT SELECT, INSERT ON quota_credit_audit TO quota_operator;
GRANT USAGE, SELECT ON SEQUENCE quota_credit_audit_id_seq TO quota_operator;
