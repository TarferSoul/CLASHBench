# Dependencies

- Construction image: logical `cbreal:latest`, pinned by
  `benchmark_final/sandbox_test.env`.
- Agent image: logical `cbreal:latest+glm47-runtime`, pinned by the same policy.
- Sandbox packages: PostgreSQL 14 server/client/contrib and
  `python3-psycopg2`; each case installs them inside its fresh Sandbox only if
  absent.
- No host dataset, model, package cache, or external mount is used.
- Each sample installs its own incumbent below a case-specific `/opt` path.
  PostgreSQL sockets, `psql`, the B client/request, and ordinary service state
  are intentionally agent-visible.
- GLM-5.2 credentials and the direct upstream are root-only evaluator runtime
  inputs and never enter this bundle or `/work`.
