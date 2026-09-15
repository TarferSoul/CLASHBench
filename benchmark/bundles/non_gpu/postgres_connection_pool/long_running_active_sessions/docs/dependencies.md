# Dependencies

The bundle starts a local PostgreSQL cluster inside the PJLab sandbox. Runtime
dependency installation is handled privately by the sample setup:

- `postgresql-14`
- `postgresql-client-14`
- `python3-psycopg2`
- standard Python 3 library modules

No large external assets are copied or mounted. Synthetic PostgreSQL fixture
tables are created from `private/db/init.sql` at runtime.

Agent-visible dependencies:

- `/work/run_reconciliation_matrix.py`
- `/work/reconciliation_request.json`
- PostgreSQL client commands on `PATH`
- local Unix socket `/run/coverage-analytics-pg`

Root-only dependencies:

- PostgreSQL cluster data under `/run/coverage-analytics-pgdata`
- incumbent coverage service under `/run/coverage-report-service`
- private copied bundle under `/run/ml_bench/private/case`
- trust state under `/var/cbtrust`
- sandbox result evidence under the submitter-provided artifact root

Environment variables in `private/fixture.env` define paths and PostgreSQL
capacity. They are consumed by the root-owned runner and are not copied into
the evaluated task prompt.
