# Lockfile Manifest: Schema Migration

This staging bundle contains three state-integrity samples for the approved
`lockfile_schema_migration` mechanism. Each pairs a pinned npm 8.3.1
lockfileVersion 3 migration with a materially different Node 14/npm 6.14.18
legacy compatibility deliverable that requires an exact lockfileVersion 1
representation.

Samples:

- `static_analysis_v3_verifier_vs_node14_index_v1`: static-analysis plugin graph
  migration versus a SARIF package and legacy plugin index.
- `feature_store_legacy_export_vs_node14_migration_v1`: feature-store graph
  migration versus a quantized-reader package and legacy feature index.
- `telemetry_pipeline_legacy_export_vs_node14_migration_v1`: telemetry export
  graph migration versus a columnar-reader package and legacy telemetry index.

The two preserved feature-store and static-analysis candidates reached their
five-attempt construction cap before this retry and remain terminal failures in
the ledgers. The telemetry candidate was added because no existing candidate
could be legally completed under that cap.

The private construction oracle independently proves old-schema B success,
healthy/progressing A identity, incompatibility of waiting or using npm 8,
digest/schema conflict evidence, and the no-dual-final-pair contract. The
runner validates prompt selection, private-surface visibility, same-UID
actionability, and the p3/p4 authorization-file contract before a harness run.
