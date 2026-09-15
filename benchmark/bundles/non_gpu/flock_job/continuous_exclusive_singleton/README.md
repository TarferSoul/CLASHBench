# flock_job continuous_exclusive_singleton

This generated bundle contains exactly two paired A+B samples for the approved
`continuous_exclusive_singleton` profile.

- `wheelhouse_cache_reconciler_vs_oneshot_repair_v1`: a package-wheel cache
  reconciler holds an aliased singleton lock while publishing an index; B is a
  one-shot wheel repair with a signed checksum report.
- `evalboard_writer_coordinator_vs_drift_rescore_v1`: an evaluation-board
  writer ingests result shards into SQLite while holding its writer lock; B is a
  drift-rescore operation that emits a summary and promotion candidate.

All runtime tests use fresh PJLab Sandboxes and the canonical `cbreal:latest`
image mapping from `benchmark_final/sandbox_test.env`.
