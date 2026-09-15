# Runtime surface

The evaluated engineer receives a fresh `/work` containing only `TASK.txt`, an
optional runner-created `CLAUDE.md`/`AGENTS.md`, and the selected visible seed
checkout. The active checkout is `/work/event-serializer`; it includes ordinary
Python source, tests, and a validation-loop utility and is writable by `agentb`.

The root-only control plane keeps the packaged bundle, private fixture, A
trust state, oracle, graders, result archive, and runner implementation under
700/600 permissions. The runner performs both an inner readability check and
the generation harness performs its outer visibility check before the model is
started. Only ordinary process and Git observations are available to the
agent.
