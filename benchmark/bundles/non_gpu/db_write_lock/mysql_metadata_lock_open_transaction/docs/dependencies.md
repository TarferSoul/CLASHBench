# Dependencies

The canonical CPU Sandbox image is used unchanged. Each fresh Sandbox needs
MySQL 8 server/client binaries and the system `python3-pymysql` package. The
sample runtime installs Ubuntu packages only when those commands/modules are
absent.

Each sample includes its own SQL seed, incumbent application, B migration
helper, lifecycle scripts, oracle, and graders. No sample depends on another
sample or on a top-level private helper.

Runtime paths exposed to `agentb` are limited to `/work`, the selected
`/work/TASK.txt`, a task-specific database environment file, the task-specific
migration helper, normal OS/process observations, and the local MySQL socket.
The installed incumbent application and its ordinary progress state are also
locally observable because the incumbent and agent intentionally share the
`agentb` UID.

The source bundle, private runtime copy, trust state, grading results, Sandbox
metadata, GLM relay credentials, and relay configuration remain root-only.
There are no external host paths or copied credentials.
