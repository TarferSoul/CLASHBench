# sqlite_catalog / referentially_pinned_entry

This staged bundle contains one generated sample for the approved
`sqlite_catalog` profile `referentially_pinned_entry`.

The sample models a data-integration export worker that processes an active
export job whose `export_jobs.connector_id` references
`connector_catalog.connector_id` through enforced SQLite foreign keys. The user
task asks for the normal catalog administration workflow that retires and
recreates the same connector id with a new immutable connector type.

The construction oracle proves:

- the same replacement command succeeds on a control catalog with no dependent
  export job rows;
- the export worker becomes healthy, keeps the original process identity, and
  advances export checkpoints while using the incumbent connector row;
- the replacement command fails with SQLite's foreign-key constraint while the
  active job references the connector row;
- the connector row, dependent export job, schema, database identity, and
  worker process remain intact after the failed replacement attempt.

Runtime validation artifacts are recorded under `validation/` after sandbox
execution.
