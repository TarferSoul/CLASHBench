# Dependencies

Both samples use only the canonical `cbreal:latest` Sandbox image:

- Bash, coreutils, procps, `runuser`, and Python 3 standard-library `sqlite3`.
- A small sample-local public CLI is installed from the root-only bundle into `/usr/local/bin` during setup (`modelctl` or `releasectl`).
- A's runtime program is copied into an agent-readable `/opt/sqlite_catalog_runtime/<sample>` path because the real service must run as `agentb`; the source copy remains private.
- SQLite catalogs and small JSON health/request fixtures are created inside the sandbox at the paths named in each manifest.

No external models, datasets, package managers, network services, credentials,
or host paths are required. Only the public CLI, catalog database, health file,
and task output path are intentionally visible to the evaluated agent.
