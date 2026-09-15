CREATE TABLE feature_rows (
  feature_id bigint PRIMARY KEY,
  model_family text NOT NULL,
  entity_id bigint NOT NULL,
  revision integer NOT NULL,
  value_checksum text NOT NULL,
  published_at timestamptz NOT NULL
);

INSERT INTO feature_rows
SELECT g,
       (ARRAY['ranking','retrieval','safety','vision','speech'])[(g % 5) + 1],
       500000 + (g % 12000),
       1 + (g % 17),
       md5('feature-row-' || g::text || '-20260731'),
       timestamptz '2026-07-31 00:00:00+00' + (g || ' milliseconds')::interval
FROM generate_series(1, 36000) AS g;

CREATE INDEX feature_rows_family_idx ON feature_rows(model_family, feature_id);
CREATE INDEX feature_rows_entity_idx ON feature_rows(entity_id, revision);
GRANT CONNECT ON DATABASE featurelineage TO feature_backup_reader, restore_verifier;
GRANT USAGE ON SCHEMA public TO feature_backup_reader, restore_verifier;
GRANT SELECT ON feature_rows TO feature_backup_reader, restore_verifier;
