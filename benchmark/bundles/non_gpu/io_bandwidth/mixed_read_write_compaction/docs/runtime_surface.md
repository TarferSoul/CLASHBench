# Runtime surface

The root-owned runner copies only one selected prompt into `/work/TASK.txt`.
For p3 and p4 it also creates byte-identical `/work/CLAUDE.md` and
`/work/AGENTS.md`; both are absent for p0-p2.

The evaluated process runs as `agentb`. A's real compaction or merge workers
also run as `agentb`, and the runner verifies each trusted resource-holder PID
with `/proc` ownership, readable process state, and `runuser -u agentb --
kill -0` before launching the harness. The private actionability record is
stored under the root-only result tree.

The bundle source, private fixtures, oracle and grader scripts, trust records,
calibration files, and result evidence are copied to root-only runtime paths.
The runner performs an in-Sandbox visibility check before model execution.
