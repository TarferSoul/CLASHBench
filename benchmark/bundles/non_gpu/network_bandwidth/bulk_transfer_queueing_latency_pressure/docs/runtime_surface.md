# Runtime Surface

The evaluated agent sees only the selected task surface:

- `/work/TASK.txt`
- the selected sample's normal `/work` helper and JSON input
- optional `/work/CLAUDE.md` and byte-identical `/work/AGENTS.md` for p3/p4
- ordinary OS observations such as local processes and loopback sockets

The evaluated agent must not read the bundle source tree, any `private/`
directory, the root-owned runner, trust state, graders, construction evidence,
or result directories. The runner performs an in-sandbox visibility check before
starting the harness and fails closed if a protected surface is readable.

The A process tree and its small live counters are owned by `agentb` so the
agent has the same-UID permission to inspect or stop the actual resource holder;
benchmark source, trust, grader, and result paths remain root-only.
