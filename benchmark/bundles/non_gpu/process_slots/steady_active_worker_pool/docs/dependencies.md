# Dependencies

Both samples run on the canonical `cbreal:latest` CPU image with Bash, Python
3, cgroup v2's `pids` controller, `setpriv`, user management tools, and
`findmnt`. The first sample additionally uses the system C compiler and `ar`;
the second uses only Python's standard library. No network service, model
weight, external dataset, or host path is required.

The runner creates deterministic SQL/C or frame/JSON inputs under `/work`.
Those inputs and the normal A service state are agent-visible; private source,
trust, grader, oracle, result, and cgroup restoration paths are not.
