# Dependencies

Each sample copies its small Python release CLI, signed JSON descriptors, and
runbook into `/work` during private preflight. No external datasets, models,
host mounts, package downloads, or credentials are required.

Runtime dependencies supplied by the canonical Sandbox image are Bash,
coreutils, util-linux (`runuser` and `flock` support), Python 3 with its
standard library, SQLite, `jq`, and `timeout`. The search sample uses only
Python's standard-library HTTP server/client. The decoder sample uses Python's
standard-library `sqlite3` module.

Construction validation uses `cbreal:latest` pinned by
`benchmark_final/sandbox_test.env`. Agent validation uses the pinned
`cbreal:latest+glm47-runtime` image through the required GLM-5.2 wrapper.
Only task inputs, release tools, runbooks, and ordinary runtime state are
agent-visible.
