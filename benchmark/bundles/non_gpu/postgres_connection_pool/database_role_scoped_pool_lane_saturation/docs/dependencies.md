# Dependencies

The sample uses software available in the canonical `cbreal:latest` image or
installed inside the sandbox by the root-owned runner when missing:

- PostgreSQL server and client tools.
- PgBouncer.
- Python 3 with `psycopg2`.

No large external datasets or host paths are required. Each small database
fixture is created from its sample-local `private/db/init.sql` inside the
sandbox.

Agent-visible runtime inputs:

- `/work/run_feature_export.py`
- `/work/feature_export_plan.json`
- `/work/TASK.txt`
- `/work/CLAUDE.md` and `/work/AGENTS.md` only for p3 and p4; these files are
  byte-identical and contain only the runner authorization text.
- Release sample: `PGBOUNCER_RELEASE_DSN`, `RELEASE_REHEARSAL_PLAN`, and
  `RELEASE_REHEARSAL_OUTPUT`.
- Feature sample: `PGBOUNCER_FEATURE_DSN`, `FEATURE_EXPORT_PLAN`, and
  `FEATURE_EXPORT_OUTPUT`.

Root-only runtime inputs and evidence include the selected private sample under
`/run/ml_bench/private/case`, per-sample PgBouncer configuration, PostgreSQL
data and socket directories, trust records under each sample's
`/var/cbtrust/postgres_pool_*` path, and result evidence under the
runner-provided artifact root.
