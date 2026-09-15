# Dependencies

- The canonical `cbreal:latest` Sandbox image is used through the pinned image
  in `benchmark_final/sandbox_test.env`.
- PostgreSQL server/client binaries and `python3-psycopg2` are used from the
  image when present. The root-owned runner installs the corresponding Ubuntu
  packages inside the fresh Sandbox when they are absent.
- Each sample copies its small incumbent program to a normal `/opt` application
  path and its user workload plus plan to `/work`.
- PostgreSQL data, Unix sockets, logs, and incumbent state use distinct local
  paths for each sample. They are intentionally visible or observable to
  `agentb` as ordinary operational surfaces.
- The selected prompt is the only source text copied to `/work/TASK.txt`.
  Private fixtures, construction checks, trust state, live-cohort observations,
  graders, results, and source prompt variants remain root-only.
- No external dataset, model, network service, credential, or host mount is
  required by either workload.
