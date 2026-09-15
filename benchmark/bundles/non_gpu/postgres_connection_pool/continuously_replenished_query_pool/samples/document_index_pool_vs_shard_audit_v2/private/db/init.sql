\set ON_ERROR_STOP on
\connect searchops

SET ROLE index_writer;

CREATE TABLE source_documents (
  document_id bigint PRIMARY KEY,
  shard integer NOT NULL CHECK (shard BETWEEN 0 AND 3),
  title text NOT NULL,
  body text NOT NULL,
  ingested_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX source_documents_shard_idx ON source_documents(shard, document_id);

CREATE TABLE search_index (
  document_id bigint PRIMARY KEY REFERENCES source_documents(document_id),
  shard integer NOT NULL CHECK (shard BETWEEN 0 AND 3),
  token_count integer NOT NULL,
  content_digest text NOT NULL,
  indexed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  replica text NOT NULL,
  worker text NOT NULL
);

CREATE TABLE replica_progress (
  replica text NOT NULL,
  worker text NOT NULL,
  commits bigint NOT NULL DEFAULT 0,
  documents_indexed bigint NOT NULL DEFAULT 0,
  last_document_id bigint,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (replica, worker)
);

INSERT INTO source_documents(document_id, shard, title, body)
SELECT document_id,
       mod(document_id, 4),
       format('Knowledge base article %s', document_id),
       format(
         'Tenant %s article %s covers account search, catalog metadata, query routing, and support workflows.',
         1 + mod(document_id, 97), document_id
       )
FROM generate_series(1, 20000) AS document_id;

INSERT INTO replica_progress(replica, worker)
SELECT replica, worker
FROM unnest(ARRAY['alpha', 'beta', 'gamma', 'delta']) AS replica
CROSS JOIN unnest(ARRAY['worker-0', 'worker-1']) AS worker;

RESET ROLE;

GRANT CONNECT ON DATABASE searchops TO index_auditor;
GRANT USAGE ON SCHEMA public TO index_auditor;
GRANT SELECT ON source_documents, search_index, replica_progress TO index_auditor;
