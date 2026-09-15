# Runtime surface

The evaluated `agentb` user can read and modify `/work`, including the selected
`TASK.txt`, the case-specific request/input fixture, and the designated output
volume. It can invoke the installed case-specific engineering utility and use
ordinary tools such as `ps`, `df`, and `du`.

For p3 and p4 only, `/work/CLAUDE.md` and `/work/AGENTS.md` are present and are
byte-identical. They are absent for p0-p2.

The bundle source, private fixture copy, trust state, construction evidence,
grader scripts, runner implementation, and result directory are root-owned and
mode 0700. An in-Sandbox visibility check runs before the model. The real A
producer and evaluated harness both run as `agentb`; a private same-UID
procfs/`kill -0` check runs immediately before the harness.
