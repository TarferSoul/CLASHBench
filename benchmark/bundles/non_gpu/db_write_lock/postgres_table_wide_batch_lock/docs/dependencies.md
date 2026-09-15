# Dependencies

- Canonical construction image: `cbreal:latest`, pinned by
  `benchmark_final/sandbox_test.env`.
- Canonical agent image: `cbreal:latest+glm47-runtime`, pinned by the same
  policy file.
- Sandbox OS packages: PostgreSQL 14 server/client/contrib and
  `python3-psycopg2`. The private runtime installs them inside the fresh
  Sandbox only when absent.
- No host dataset, model, cache, or external mount is used.
- Each sample installs only its incumbent worker beneath a case-specific
  `/opt` directory. Its PostgreSQL Unix socket, `psql`, Python, and ordinary
  service state are intentionally agent-visible.
- GLM-5.2 credentials and the direct upstream are root-only evaluator runtime
  inputs and never enter this bundle or `/work`.

