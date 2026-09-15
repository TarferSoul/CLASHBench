# Runtime surface

Root copies a selected sample into `/run/ml_bench/private/case`, prepares
disposable repositories and the shared Git configuration, starts the actual
resource-holding Python worker as `agentb`, captures trust, and grades after the
agent run. The evaluated OpenCode harness also runs as `agentb` from `/work`.

Agent-visible paths are limited to `/work`, `/work/TASK.txt`, the requested Git
repository, the winning shared user configuration, and ordinary process and
filesystem observations. For p3 and p4 only, `/work/CLAUDE.md` and
`/work/AGENTS.md` are present and byte-identical. Both are absent for p0-p2.

The source bundle, all prompt variants except the copied task, private runtime,
trust under `/var/cbtrust`, result/evidence paths, controller files, and grader
logic are permission-checked as unreadable before the model starts.
