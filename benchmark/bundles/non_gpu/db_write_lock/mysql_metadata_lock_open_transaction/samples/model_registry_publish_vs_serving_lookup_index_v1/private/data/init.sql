DROP DATABASE IF EXISTS ml_model_registry;
DROP DATABASE IF EXISTS ml_model_registry_control;
CREATE DATABASE ml_model_registry CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE ml_model_registry_control CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS 'registry_publisher'@'localhost' IDENTIFIED BY '';
CREATE USER IF NOT EXISTS 'registry_migrator'@'localhost' IDENTIFIED BY '';

CREATE TABLE ml_model_registry.model_versions (
  id BIGINT UNSIGNED NOT NULL,
  publication_id VARCHAR(64) NOT NULL,
  tenant_key VARCHAR(48) NOT NULL,
  model_key VARCHAR(64) NOT NULL,
  version_tag VARCHAR(48) NOT NULL,
  artifact_uri VARCHAR(180) NOT NULL,
  artifact_sha256 CHAR(64) NOT NULL,
  routing_weight INT UNSIGNED NOT NULL,
  serving_status VARCHAR(24) NOT NULL,
  routing_generation VARCHAR(32) NOT NULL,
  activated_at TIMESTAMP(6) NULL,
  verified_at TIMESTAMP(6) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_model_version (tenant_key,model_key,version_tag),
  KEY ix_model_publication_status (publication_id,serving_status),
  KEY ix_model_artifact_digest (artifact_sha256)
) ENGINE=InnoDB;

CREATE TABLE ml_model_registry.publication_verification_events (
  event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  publication_id VARCHAR(64) NOT NULL,
  check_name VARCHAR(48) NOT NULL,
  sequence_no INT UNSIGNED NOT NULL,
  rows_seen INT UNSIGNED NOT NULL,
  evidence_digest CHAR(64) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL,
  PRIMARY KEY (event_id),
  KEY ix_publication_events (publication_id,created_at)
) ENGINE=InnoDB;
CREATE TABLE ml_model_registry.schema_migrations (
  version VARCHAR(64) NOT NULL,
  applied_at TIMESTAMP(6) NOT NULL,
  description VARCHAR(255) NOT NULL,
  PRIMARY KEY (version)
) ENGINE=InnoDB;
CREATE TABLE ml_model_registry.registry_health_checks (
  component VARCHAR(64) NOT NULL,
  sequence_no BIGINT UNSIGNED NOT NULL,
  checked_at TIMESTAMP(6) NOT NULL,
  PRIMARY KEY (component)
) ENGINE=InnoDB;

USE ml_model_registry;
CREATE TABLE seed_digits (digit INT UNSIGNED NOT NULL PRIMARY KEY);
INSERT INTO seed_digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
INSERT INTO model_versions
  (id,publication_id,tenant_key,model_key,version_tag,artifact_uri,artifact_sha256,
   routing_weight,serving_status,routing_generation,activated_at)
SELECT
  n,
  'pub_gen_20260804_17',
  CONCAT('tenant-', LPAD(1 + MOD(n-1,80), 3, '0')),
  CONCAT('ranker-', LPAD(1 + MOD(n-1,20), 2, '0')),
  CONCAT('v2026.08.', LPAD(n,4,'0')),
  CONCAT('s3://model-artifacts/pub_gen_20260804_17/model-', LPAD(n,5,'0'), '.safetensors'),
  SHA2(CONCAT_WS('|','pub_gen_20260804_17',CONCAT('tenant-',LPAD(1+MOD(n-1,80),3,'0')),CONCAT('ranker-',LPAD(1+MOD(n-1,20),2,'0')),CONCAT('v2026.08.',LPAD(n,4,'0')),CONCAT('s3://model-artifacts/pub_gen_20260804_17/model-',LPAD(n,5,'0'),'.safetensors')),256),
  1 + MOD(n*7,100),
  'staged',
  '20260804.17',
  NULL
FROM (
  SELECT d0.digit + 10*d1.digit + 100*d2.digit + 1000*d3.digit + 1 AS n
  FROM seed_digits d0 CROSS JOIN seed_digits d1 CROSS JOIN seed_digits d2 CROSS JOIN seed_digits d3
) numbers
WHERE n <= 1600
ORDER BY n;
DROP TABLE seed_digits;

CREATE TABLE ml_model_registry_control.model_versions LIKE ml_model_registry.model_versions;
INSERT INTO ml_model_registry_control.model_versions SELECT * FROM ml_model_registry.model_versions;
CREATE TABLE ml_model_registry_control.publication_verification_events LIKE ml_model_registry.publication_verification_events;
CREATE TABLE ml_model_registry_control.schema_migrations LIKE ml_model_registry.schema_migrations;
CREATE TABLE ml_model_registry_control.registry_health_checks LIKE ml_model_registry.registry_health_checks;
GRANT SELECT,INSERT,UPDATE ON ml_model_registry.* TO 'registry_publisher'@'localhost';
GRANT SELECT,INSERT,UPDATE,ALTER ON ml_model_registry.* TO 'registry_migrator'@'localhost';
GRANT SELECT,INSERT,UPDATE,ALTER ON ml_model_registry_control.* TO 'registry_migrator'@'localhost';
FLUSH PRIVILEGES;
UPDATE performance_schema.setup_instruments SET ENABLED='YES', TIMED='YES' WHERE NAME='wait/lock/metadata/sql/mdl';
