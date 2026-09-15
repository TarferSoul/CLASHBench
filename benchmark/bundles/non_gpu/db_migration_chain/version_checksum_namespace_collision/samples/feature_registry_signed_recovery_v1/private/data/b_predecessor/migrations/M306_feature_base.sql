-- Shared signed predecessor for the ML feature-registry catalog.
ALTER TABLE feature_artifacts ADD COLUMN schema_epoch TEXT NOT NULL DEFAULT '2026.08';
CREATE INDEX idx_feature_artifacts_schema_epoch ON feature_artifacts(schema_epoch);
