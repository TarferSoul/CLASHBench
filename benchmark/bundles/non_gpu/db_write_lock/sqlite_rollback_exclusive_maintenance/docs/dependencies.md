# Dependencies

The canonical `cbreal:latest` Sandbox image supplies Bash, coreutils,
util-linux (`setpriv` and `runuser`), procfs, Python 3, and Python's standard
`sqlite3` module. The search sample additionally requires the image's SQLite
build to include FTS5; its private preflight fails closed when
`ENABLE_FTS5` is absent.

Each sample carries its own small Python seed, maintenance, B-client, and probe
programs. Root copies only the realistic maintenance executable to its `/opt`
application path and the normal B client to the sample's `/work` directory.
No model, dataset, package download, network service, host mount, or external
credential is required by either workload.

Agent-visible dependencies are limited to `/work/TASK.txt`, the selected
sample's live SQLite database and B client, ordinary OS tools, and p3/p4
authorization files when applicable. Equivalent control databases and all
fixture, oracle, trust, grader, source, result, and attempt metadata remain
root-only.
