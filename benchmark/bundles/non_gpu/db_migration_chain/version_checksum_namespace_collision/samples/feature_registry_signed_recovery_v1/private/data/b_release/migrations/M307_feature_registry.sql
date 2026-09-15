-- Recovery M307 records immutable provenance digests required by certification.
-- depends: M306_feature_base
ALTER TABLE feature_artifacts ADD COLUMN provenance_digest TEXT NOT NULL DEFAULT '';
UPDATE feature_artifacts
SET provenance_digest = lower(hex(
    artifact_id || ':' || model_family || ':' || object_sha256 || ':' || lifecycle
));
CREATE TABLE provenance_requirement (
    policy_id TEXT PRIMARY KEY,
    minimum_digest_length INTEGER NOT NULL,
    attestor TEXT NOT NULL
);
INSERT INTO provenance_requirement(policy_id, minimum_digest_length, attestor)
VALUES ('recovery-2026.08', 64, 'model-registry-recovery-2026');
CREATE INDEX idx_feature_artifacts_provenance
    ON feature_artifacts(provenance_digest, lifecycle);
