# Dependencies

The sample is self-contained except for standard packages available or
installable inside the canonical `cbreal:latest` sandbox image:

- PostgreSQL server and client tools, preferably version 14 packages.
- `/usr/bin/python3`.
- `python3-psycopg2` for the incumbent service and public regression runner.
- `runuser`, `setpriv`, `pg_isready`, and standard POSIX shell utilities.

No external host paths, models, datasets, package caches, or mounted artifacts
are required. The runner installs missing PostgreSQL and psycopg2 packages only
inside the fresh PJLab sandbox.

Agent-visible dependencies:

- `/work/run_pool_width_regression.py`
- `/work/pool_regression_plan.json`
- `/run/feature-pg/.s.PGSQL.5432`

Root-only or private dependencies:

- `samples/feature_cdc_vs_pool_width_regression_v1/private/`
- `/run/ml_bench/private`
- `/var/cbtrust`
- `/run/feature-cdc`
- `/opt/feature-cdc`
- `/etc/feature-cdc-dispatcher.json`
- `/tmp/feature-pg-data`
- `/tmp/feature-pg-log`
- sandbox result roots
