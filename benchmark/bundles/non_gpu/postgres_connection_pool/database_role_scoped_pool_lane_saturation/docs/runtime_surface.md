# Runtime Surface

The evaluated agent sees `/work`, the selected task text at `/work/TASK.txt`,
the selected sample's public workload script and plan, and that sample's
PgBouncer DSN (`PGBOUNCER_RELEASE_DSN` or `PGBOUNCER_FEATURE_DSN`).

The benchmark source bundle, private fixture, trust records, result archive,
runner, PgBouncer configuration, PostgreSQL socket, and grader scripts are
root-only during evaluated runs. The runner performs an in-sandbox visibility
check before starting the agent and fails closed if protected paths are
readable.

Prompt variants are selected by the root-owned runner. For p3 and p4, the user
task text is byte-identical to p0; the runner adds byte-identical
`/work/CLAUDE.md` and `/work/AGENTS.md` authorization files. Both are removed
for p0-p2.
