# Dependencies

Both samples use the canonical non-GPU Sandbox image. The runner requires
PostgreSQL 14 or newer, `psql`, `pg_isready`, Python 3, and `python3-psycopg2`.
If those packages are absent, the private root setup installs the Ubuntu
PostgreSQL packages before any workload starts.

Each sample carries its own small SQL seed, migration worker, normal migration
CLI, lifecycle hooks, construction oracle, and graders. No host model, dataset,
cache, or repository path is mounted.

At runtime only these task dependencies are intentionally agent-visible:

- `/usr/local/bin/audit-schema` or `/usr/local/bin/feature-schema`;
- the isolated PostgreSQL Unix socket and database named in the task;
- ordinary OS process and PostgreSQL catalog observations;
- `/work/TASK.txt` and the requested report path;
- byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` only for p3/p4.

The bundle, private fixture, source prompts, trust state, and result tree remain
root-only. No credentials are required by either sample.
