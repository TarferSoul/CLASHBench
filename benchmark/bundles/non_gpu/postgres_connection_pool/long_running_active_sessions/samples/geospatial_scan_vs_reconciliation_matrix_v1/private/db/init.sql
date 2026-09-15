\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS coverage CASCADE;
CREATE SCHEMA coverage;
CREATE TABLE coverage.regions (
  region_id integer PRIMARY KEY,
  region_code text NOT NULL,
  release_channel text NOT NULL
);
CREATE TABLE coverage.coverage_tiles (
  tile_id integer PRIMARY KEY,
  region_id integer NOT NULL REFERENCES coverage.regions(region_id),
  tile_key text NOT NULL,
  area_km2 numeric(12,3) NOT NULL,
  quality_score integer NOT NULL,
  captured_on date NOT NULL
);
CREATE TABLE coverage.expected_matrix (
  region_id integer NOT NULL,
  release_id integer NOT NULL,
  expected_tiles integer NOT NULL,
  PRIMARY KEY(region_id, release_id)
);
CREATE TABLE coverage.release_catalog (
  release_id integer PRIMARY KEY,
  release_name text NOT NULL,
  published_on date NOT NULL
);
INSERT INTO coverage.regions
SELECT g, 'region-' || lpad(g::text, 2, '0'), (ARRAY['stable','canary'])[(g % 2) + 1]
FROM generate_series(0,22) AS g;
INSERT INTO coverage.coverage_tiles
SELECT g, (g - 1) % 23, 'tile-' || lpad(g::text, 7, '0'),
       ((g % 700) + 1)::numeric / 10, 50 + (g % 51), date '2025-01-01' + (g % 180)
FROM generate_series(1,11500) AS g;
INSERT INTO coverage.release_catalog
SELECT g, 'coverage-r' || g::text, date '2025-01-01' + g
FROM generate_series(1,6) AS g;
INSERT INTO coverage.expected_matrix
SELECT region_id, release_id, 500
FROM coverage.regions CROSS JOIN coverage.release_catalog;
CREATE INDEX coverage_tiles_region_idx ON coverage.coverage_tiles(region_id, tile_id);
CREATE INDEX coverage_tiles_capture_idx ON coverage.coverage_tiles(captured_on, region_id);
ANALYZE coverage.regions;
ANALYZE coverage.coverage_tiles;
ANALYZE coverage.expected_matrix;
ANALYZE coverage.release_catalog;
GRANT CONNECT ON DATABASE geoanalytics TO coverage_reader, release_reconciler;
GRANT USAGE ON SCHEMA coverage TO coverage_reader, release_reconciler;
GRANT SELECT ON ALL TABLES IN SCHEMA coverage TO coverage_reader, release_reconciler;
