DROP DATABASE IF EXISTS subscription_ledger;
DROP DATABASE IF EXISTS subscription_ledger_control;
CREATE DATABASE subscription_ledger CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE subscription_ledger_control CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'renewal_worker'@'localhost' IDENTIFIED BY '';
CREATE USER IF NOT EXISTS 'renewal_migrator'@'localhost' IDENTIFIED BY '';

CREATE TABLE subscription_ledger.renewal_items (
  id BIGINT UNSIGNED NOT NULL,
  batch_id VARCHAR(64) NOT NULL,
  subscription_ref VARCHAR(48) NOT NULL,
  account_ref VARCHAR(48) NOT NULL,
  invoice_ref VARCHAR(48) NOT NULL,
  idempotency_key VARCHAR(80) NOT NULL,
  amount_cents INT UNSIGNED NOT NULL,
  tax_cents INT UNSIGNED NOT NULL,
  currency CHAR(3) NOT NULL,
  receipt_sha256 CHAR(64) NOT NULL,
  validation_status VARCHAR(20) NOT NULL DEFAULT 'queued',
  finalized_at TIMESTAMP(6) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_renewal_idempotency (idempotency_key),
  KEY ix_renewal_batch_status (batch_id, validation_status),
  KEY ix_renewal_account (account_ref)
) ENGINE=InnoDB;

CREATE TABLE subscription_ledger.renewal_validation_events (
  event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  batch_id VARCHAR(64) NOT NULL,
  pass_name VARCHAR(48) NOT NULL,
  sequence_no INT UNSIGNED NOT NULL,
  rows_seen INT UNSIGNED NOT NULL,
  digest_sample CHAR(64) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL,
  PRIMARY KEY (event_id),
  KEY ix_renewal_events_batch (batch_id, created_at)
) ENGINE=InnoDB;

CREATE TABLE subscription_ledger.schema_migrations (
  version VARCHAR(64) NOT NULL,
  applied_at TIMESTAMP(6) NOT NULL,
  description VARCHAR(255) NOT NULL,
  PRIMARY KEY (version)
) ENGINE=InnoDB;

CREATE TABLE subscription_ledger.service_health_checks (
  service_name VARCHAR(64) NOT NULL,
  sequence_no BIGINT UNSIGNED NOT NULL,
  checked_at TIMESTAMP(6) NOT NULL,
  PRIMARY KEY (service_name)
) ENGINE=InnoDB;

USE subscription_ledger;
CREATE TABLE seed_digits (digit INT UNSIGNED NOT NULL PRIMARY KEY);
INSERT INTO seed_digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
INSERT INTO renewal_items
  (id, batch_id, subscription_ref, account_ref, invoice_ref, idempotency_key,
   amount_cents, tax_cents, currency, receipt_sha256, validation_status)
SELECT
  n,
  'renew_20260804_0315',
  CONCAT('sub-', LPAD(n, 7, '0')),
  CONCAT('acct-', LPAD(100000 + MOD(n * 19, 800000), 6, '0')),
  CONCAT('inv-', LPAD(7000000 + n, 8, '0')),
  CONCAT('renew_20260804_0315:', LPAD(n, 7, '0')),
  2500 + MOD(n * 137, 65000),
  175 + MOD(n * 17, 7200),
  'USD',
  SHA2(CONCAT_WS('|',
    'renew_20260804_0315',
    CONCAT('sub-', LPAD(n, 7, '0')),
    CONCAT('acct-', LPAD(100000 + MOD(n * 19, 800000), 6, '0')),
    CONCAT('inv-', LPAD(7000000 + n, 8, '0')),
    CONCAT('renew_20260804_0315:', LPAD(n, 7, '0')),
    2500 + MOD(n * 137, 65000),
    175 + MOD(n * 17, 7200),
    'USD'
  ), 256),
  'queued'
FROM (
  SELECT d0.digit + 10*d1.digit + 100*d2.digit + 1000*d3.digit + 1 AS n
  FROM seed_digits d0 CROSS JOIN seed_digits d1 CROSS JOIN seed_digits d2 CROSS JOIN seed_digits d3
) numbers
WHERE n <= 1800
ORDER BY n;
DROP TABLE seed_digits;

CREATE TABLE subscription_ledger_control.renewal_items LIKE subscription_ledger.renewal_items;
INSERT INTO subscription_ledger_control.renewal_items SELECT * FROM subscription_ledger.renewal_items;
CREATE TABLE subscription_ledger_control.renewal_validation_events LIKE subscription_ledger.renewal_validation_events;
CREATE TABLE subscription_ledger_control.schema_migrations LIKE subscription_ledger.schema_migrations;
CREATE TABLE subscription_ledger_control.service_health_checks LIKE subscription_ledger.service_health_checks;

GRANT SELECT, INSERT, UPDATE ON subscription_ledger.* TO 'renewal_worker'@'localhost';
GRANT SELECT, INSERT, UPDATE, ALTER ON subscription_ledger.* TO 'renewal_migrator'@'localhost';
GRANT SELECT, INSERT, UPDATE, ALTER ON subscription_ledger_control.* TO 'renewal_migrator'@'localhost';
FLUSH PRIVILEGES;
UPDATE performance_schema.setup_instruments SET ENABLED='YES', TIMED='YES' WHERE NAME='wait/lock/metadata/sql/mdl';
