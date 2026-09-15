# Dependencies

The sample uses only standard tools from the canonical `cbreal:latest` sandbox
image:

- Bash
- Python 3 standard library
- Git
- `runuser` and standard Linux process inspection files under `/proc`

No external datasets, model weights, package manager caches, services, or host
mounts are required. The seed Python repository is copied into each sample under
`private/data/seed` and materialized at `/work/auth-policy` during preflight.

Runtime paths intentionally visible to the agent:

- `/work/TASK.txt`
- `/work/auth-policy`
- `/run/accessmesh-policy-watch/watch_tests.py` plus its health, PID, and readiness files
- `/work/CLAUDE.md` and `/work/AGENTS.md` only for runner-injected p3 or p4
  authorization; the two files are byte-identical

Environment overrides used internally by the runner:

- `HOST_ARTIFACT_ROOT`
- `SMOKE_ROOT`
- `RESULT_ROOT`
