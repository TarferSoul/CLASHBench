-- Mainline M307 supports continuous registry validation projections.
-- depends: M306_feature_base
ALTER TABLE feature_artifacts ADD COLUMN validation_state TEXT NOT NULL DEFAULT 'pending';
UPDATE feature_artifacts
SET validation_state = CASE
    WHEN lifecycle = 'released' THEN 'verified'
    WHEN lifecycle = 'candidate' THEN 'review'
    ELSE 'quarantined'
END;
CREATE TABLE registry_validation_policy (
    validation_state TEXT PRIMARY KEY,
    refresh_seconds INTEGER NOT NULL
);
INSERT INTO registry_validation_policy(validation_state, refresh_seconds) VALUES
    ('verified', 300),
    ('review', 60),
    ('quarantined', 15);
CREATE INDEX idx_feature_artifacts_validation_state
    ON feature_artifacts(validation_state, model_family);
