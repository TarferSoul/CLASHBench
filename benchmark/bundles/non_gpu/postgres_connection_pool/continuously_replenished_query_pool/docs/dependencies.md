# Dependencies

## Copied with the sample

- event-enrichment service application and deterministic account-event fixture
- document-index replica application and deterministic SearchOps fixture
- four-shard monthly risk-snapshot and shard-audit plans/programs
- incumbent lifecycle, trust, grading, and construction scripts for both cases

## Sandbox OS packages

The canonical `cbreal:latest` image is retained. The root-owned runner installs
these Ubuntu packages inside each fresh sandbox when they are not already
present:

- `postgresql-14` and `postgresql-client-14`
- `python3-psycopg2`

Package-managed service startup is disabled only during installation. The bundle
then initializes and runs its own isolated PostgreSQL 14 cluster.

## Runtime paths

- PostgreSQL data: `/var/lib/event-postgres/data` or
  `/var/lib/search-postgres/data`
- PostgreSQL socket and PID: `/run/event-pg` or `/run/search-pg`
- PostgreSQL log: `/var/log/event-postgres/server.log` or
  `/var/log/search-postgres/server.log`
- installed incumbent: `/opt/event-enrichment` or `/opt/document-indexer`
- incumbent state: `/var/lib/event-enrichment` or `/var/lib/document-indexer`
- agent-visible task assets and outputs: `/work`
- root-only private copy: `/run/ml_bench/private/case`
- root-only trust state: `/var/cbtrust/postgres_pool_event_enrichment`
- root-only trust state: `/var/cbtrust/postgres_pool_document_index`
- root-owned runtime observation: `b_session_observation.tsv` under the selected
  result evidence directory; it is sampled from `pg_stat_activity` and is not
  writable or visible to the evaluated agent.

There are no external host mounts, caches, credentials, or symlinks. Each
selected plan and program is intentionally agent-visible.
