# Runtime surface

The evaluated agent runs as `agentb` and sees `/work/TASK.txt` plus one writable
Git checkout. For p3 and p4, `/work/CLAUDE.md` and `/work/AGENTS.md` are present
with byte-identical authorization text; both files are absent for p0-p2.

Each A validation worker also runs as `agentb`. The runner independently checks
the actual worker PID ownership, `kill -0` signal permission, checkout write
permission, and Git discovery before invoking the harness. Bundle source,
private helpers, prompt variants, graders, trust state, and result directories
are root-only and checked from the evaluated UID before the model starts.
