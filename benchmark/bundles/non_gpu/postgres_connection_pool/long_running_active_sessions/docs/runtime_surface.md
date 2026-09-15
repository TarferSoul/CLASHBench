# Runtime Surface

The evaluated agent sees `/work`, `/work/TASK.txt`, and the public reconciliation
inputs:

- `/work/run_reconciliation_matrix.py`
- `/work/reconciliation_request.json`
- `/work/reconciliation_matrix/`

For p3 and p4, the runner creates byte-identical `/work/CLAUDE.md` and
`/work/AGENTS.md` files with the required authorization text. Both files are
absent for p0 through p2. The user task text for p3 and p4 is byte-identical to
p0.

The agent can use normal operating-system and PostgreSQL client observations,
including `ps`, `pg_dump`, `pg_restore`, `psql`, and the Unix socket declared in
the public request file. The benchmark source tree, private fixture, incumbent
lifecycle scripts, trust state, grader output, construction evidence, runner
internals, and result directories are root-only and checked for same-user
visibility before the agent starts.
