\set ON_ERROR_STOP on

CREATE TABLE alembic_version (
  version_num text PRIMARY KEY
);

INSERT INTO alembic_version(version_num)
VALUES ('20260719_invoice_event_base');

CREATE TABLE tenant_release_targets (
  tenant_id integer PRIMARY KEY,
  shard_id text NOT NULL,
  expected_start_revision text NOT NULL,
  target_revision text NOT NULL
);

INSERT INTO tenant_release_targets(tenant_id, shard_id, expected_start_revision, target_revision)
VALUES
  (4101, 'shard-a', '20260719_invoice_event_base', '20260726_add_invoice_event_columns'),
  (4102, 'shard-b', '20260719_invoice_event_base', '20260726_add_invoice_event_columns'),
  (4103, 'shard-c', '20260719_invoice_event_base', '20260726_add_invoice_event_columns'),
  (4104, 'shard-d', '20260719_invoice_event_base', '20260726_add_invoice_event_columns'),
  (4105, 'shard-e', '20260719_invoice_event_base', '20260726_add_invoice_event_columns'),
  (4106, 'shard-f', '20260719_invoice_event_base', '20260726_add_invoice_event_columns');

CREATE TABLE invoice_event_stage (
  event_id bigserial PRIMARY KEY,
  tenant_id integer NOT NULL REFERENCES tenant_release_targets(tenant_id),
  invoice_id bigint NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('created', 'rated', 'posted')),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  event_payload jsonb NOT NULL,
  source_revision text NOT NULL DEFAULT '20260719_invoice_event_base'
);

INSERT INTO invoice_event_stage(tenant_id, invoice_id, event_type, amount_cents, event_payload)
SELECT tenant_id,
       tenant_id * 100000 + ordinal,
       CASE ordinal % 3 WHEN 0 THEN 'created' WHEN 1 THEN 'rated' ELSE 'posted' END,
       900 + ((tenant_id * ordinal * 17) % 250000),
       jsonb_build_object('tenant', tenant_id, 'ordinal', ordinal, 'source', 'shadow-fixture')
FROM tenant_release_targets
CROSS JOIN generate_series(1, 180) AS ordinal;

CREATE TABLE release_contract_scratch (
  worker_name text NOT NULL,
  tenant_id integer NOT NULL,
  revision text NOT NULL,
  probe_checksum text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE release_contract_progress (
  worker_name text PRIMARY KEY,
  worker_index integer NOT NULL,
  revision text NOT NULL,
  completed_shards bigint NOT NULL DEFAULT 0,
  last_tenant_id integer,
  last_checksum text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE release_lane_control (
  component text PRIMARY KEY,
  generation text NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO release_lane_control(component, generation)
VALUES ('release-shadow-control', 'release-shadow-20260726-r1');

GRANT USAGE ON SCHEMA public TO release_runner, release_observer;
GRANT SELECT ON alembic_version TO release_runner;
GRANT SELECT ON tenant_release_targets TO release_runner;
GRANT SELECT ON invoice_event_stage TO release_runner;
GRANT SELECT, INSERT, DELETE ON release_contract_scratch TO release_runner;
GRANT SELECT, INSERT, UPDATE ON release_contract_progress TO release_runner;
GRANT SELECT ON release_lane_control TO release_observer;

