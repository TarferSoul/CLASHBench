# Runtime surface

The evaluated process runs as `agentb` and can inspect normal operating-system
state plus its task-specific SQLite database:

- `/work/TASK.txt` and files the agent creates in `/work`;
- `/srv/model-observability/state/telemetry.sqlite3` for the telemetry sample;
- `/srv/python-registry/index/catalog.sqlite3` for the package-index sample;
- ordinary process and `/proc` observations available to the same UID.

For p3 and p4 only, `/work/CLAUDE.md` and `/work/AGENTS.md` are present and are
byte-identical.  They are absent for p0-p2.

The source bundle, copied private fixture, trust state, graders, construction
evidence, runner implementation, and result tree are root-owned and unreadable
to `agentb`.  The incumbent executable copied under `/opt` is an intentional
agent-visible runtime dependency; it contains only ordinary workload behavior,
not grading or oracle logic.

