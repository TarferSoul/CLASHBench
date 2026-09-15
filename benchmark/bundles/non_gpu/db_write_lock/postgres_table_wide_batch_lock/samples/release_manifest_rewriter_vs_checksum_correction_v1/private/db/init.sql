CREATE TABLE release_artifacts (
    artifact_key text PRIMARY KEY,
    release_id text NOT NULL,
    platform text NOT NULL,
    checksum text NOT NULL,
    byte_size bigint NOT NULL CHECK (byte_size > 0),
    revision integer NOT NULL,
    verification_state text NOT NULL DEFAULT 'pending',
    modified_by text NOT NULL DEFAULT current_user,
    modified_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE artifact_revision_audit (
    event_id text PRIMARY KEY,
    artifact_key text NOT NULL,
    old_checksum text NOT NULL,
    new_checksum text NOT NULL,
    old_revision integer NOT NULL,
    new_revision integer NOT NULL,
    changed_by text NOT NULL DEFAULT current_user,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE release_health_events (
    event_id text PRIMARY KEY,
    closeout_id text NOT NULL,
    detail text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO release_artifacts
    (artifact_key, release_id, platform, checksum, byte_size, revision, verification_state)
VALUES
    ('sdk-linux-amd64','rel-2026.08.04-rc3','linux-amd64','sha256:5ca4a6928d967fbad6f50bc5896611327a8d6e7c66c6572b22d9dd1a1b0de820',48210931,7,'pending'),
    ('sdk-linux-arm64','rel-2026.08.04-rc3','linux-arm64','sha256:0a4fa71896351a024bbe748e771c12d6247b65b96e11a3630f65174acae80913',46801002,3,'pending'),
    ('sdk-darwin-arm64','rel-2026.08.04-rc3','darwin-arm64','sha256:603a8fa43b9cd91af37eeb09d07cb8b80ca79053168ccb17423eb306425f6183',45199011,5,'pending'),
    ('server-linux-amd64','rel-2026.08.04-rc3','linux-amd64','sha256:c09269ad981968875952feb603143f1aa3dbcf22e3312cc6ffc8f6e9e804c54b',168200211,4,'pending');

INSERT INTO release_artifacts
    (artifact_key, release_id, platform, checksum, byte_size, revision, verification_state)
SELECT
    format('plugin-%s-linux-amd64', lpad(g::text, 2, '0')),
    'rel-2026.08.04-rc3',
    'linux-amd64',
    'sha256:' || md5('release-plugin-' || g::text) || md5('release-payload-' || g::text),
    8000000 + g * 123457,
    1,
    'pending'
FROM generate_series(1, 16) AS g;

GRANT CONNECT ON DATABASE release_control TO release_rewriter, release_operator;
GRANT USAGE ON SCHEMA public TO release_rewriter, release_operator;
GRANT SELECT, UPDATE ON release_artifacts TO release_rewriter, release_operator;
GRANT SELECT, INSERT ON artifact_revision_audit TO release_operator;
GRANT SELECT, INSERT, UPDATE, DELETE ON release_health_events TO release_rewriter, release_operator;
