# Dependencies

- Canonical runtime image: `cbreal:latest` mapped by
  `benchmark_final/sandbox_test.env` to the pinned CPU registry image.
- Required OS/Python facilities: Python 3, `multiprocessing.shared_memory`,
  `http.server`, `runuser`, `setsid`, `ps`, `stat`, `df`, and standard POSIX
  `/dev/shm` support.
- The small feature fixture and task implementation are copied into
  `/work/input` and `/work/feature_normalization`; they are intentionally
  agent-visible task inputs.
- The incumbent service implementation is copied at runtime to an
  agent-owned service directory under `/var/lib/embedding-cache`; benchmark
  source and private data remain root-only.
- No external model, dataset, network service, credentials, or host path is
  required. The runner removes proxy variables from the evaluated environment.
