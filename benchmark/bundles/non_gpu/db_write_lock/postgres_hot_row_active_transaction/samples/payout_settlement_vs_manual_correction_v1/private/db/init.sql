CREATE EXTENSION IF NOT EXISTS pgrowlocks;

CREATE TABLE payouts (
  payout_id text PRIMARY KEY,
  merchant_id text NOT NULL,
  currency text NOT NULL,
  gross_cents bigint NOT NULL,
  correction_cents bigint NOT NULL DEFAULT 0,
  status text NOT NULL,
  revision integer NOT NULL,
  settlement_batch_id text,
  last_correction_reason text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ledger_legs (
  payout_id text NOT NULL REFERENCES payouts(payout_id),
  leg_no integer NOT NULL,
  account_code text NOT NULL,
  direction text NOT NULL CHECK (direction IN ('debit', 'credit')),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL,
  digest text NOT NULL,
  PRIMARY KEY (payout_id, leg_no)
);

CREATE TABLE automated_risk_decisions (
  payout_id text PRIMARY KEY REFERENCES payouts(payout_id),
  decision text NOT NULL,
  handoff_token text NOT NULL,
  model_generation text NOT NULL,
  decided_at timestamptz NOT NULL
);

CREATE TABLE settlement_runs (
  batch_id text PRIMARY KEY,
  payout_id text NOT NULL REFERENCES payouts(payout_id),
  ledger_leg_count integer NOT NULL,
  validation_count integer NOT NULL,
  handoff_token text NOT NULL,
  ledger_checksum text NOT NULL,
  committed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE payout_audit (
  id bigserial PRIMARY KEY,
  payout_id text NOT NULL REFERENCES payouts(payout_id),
  revision integer NOT NULL,
  delta_cents bigint NOT NULL,
  reason text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  actor text NOT NULL DEFAULT current_user,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE service_controls (
  control_key text PRIMARY KEY,
  sequence_no integer NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO payouts (
  payout_id, merchant_id, currency, gross_cents, correction_cents,
  status, revision, settlement_batch_id, last_correction_reason
) VALUES (
  'PAYOUT-HKG-82417', 'MERCHANT-HKG-264', 'HKD', 1843200, 0,
  'ready_for_settlement', 17, NULL, NULL
);

INSERT INTO ledger_legs (
  payout_id, leg_no, account_code, direction, amount_cents, currency, digest
)
SELECT
  'PAYOUT-HKG-82417',
  n,
  format('acct_%s', lpad(n::text, 3, '0')),
  CASE WHEN n % 2 = 1 THEN 'debit' ELSE 'credit' END,
  10000 + (((n + 1) / 2) * 37),
  'HKD',
  md5(format('PAYOUT-HKG-82417:%s:%s', n, 10000 + (((n + 1) / 2) * 37)))
FROM generate_series(1, 64) AS n;

INSERT INTO automated_risk_decisions (
  payout_id, decision, handoff_token, model_generation, decided_at
) VALUES (
  'PAYOUT-HKG-82417', 'approved', 'risk-clear-hkg-82417-v5',
  'risk-model-2026-08-r5', clock_timestamp()
);

INSERT INTO service_controls(control_key, sequence_no)
VALUES ('database-health', 0);

GRANT CONNECT ON DATABASE settlement_ops TO settlement_worker, settlement_operator;
GRANT CONNECT ON DATABASE settlement_control TO settlement_worker, settlement_operator;
GRANT USAGE ON SCHEMA public TO settlement_worker, settlement_operator;
GRANT SELECT, UPDATE ON payouts TO settlement_worker;
GRANT SELECT ON ledger_legs, automated_risk_decisions TO settlement_worker;
GRANT INSERT, SELECT ON settlement_runs TO settlement_worker;
GRANT SELECT, UPDATE ON payouts TO settlement_operator;
GRANT SELECT, INSERT ON payout_audit TO settlement_operator;
GRANT USAGE, SELECT ON SEQUENCE payout_audit_id_seq TO settlement_operator;
GRANT SELECT, UPDATE ON service_controls TO settlement_operator;
