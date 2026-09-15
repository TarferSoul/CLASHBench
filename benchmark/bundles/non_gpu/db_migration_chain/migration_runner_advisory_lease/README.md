# Migration runner lease samples

This staged bundle contains two paired A+B samples for the approved
`db_migration_chain/migration_runner_advisory_lease` mechanism.

Both cases run a local PostgreSQL cluster as `agentb`. A real migration client
owned by the same user holds the selected migration namespace lease while it
applies useful ordered changes. The evaluated task uses the repository's normal
B migration command against that exact database and namespace.

Runtime work is supported only through `bin/run_case.sh` with
`BENCHMARK_SANDBOX=1`. Source fixtures, graders, trust state, results, and
prompt-selection labels are root-only in the Sandbox.
