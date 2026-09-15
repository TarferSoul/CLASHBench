# Dependencies

The sample uses only software available in the canonical image:

- Bash and GNU core utilities, `findmnt`, `setpriv`, `unshare`, `timeout`, and
  `ps`;
- Python 3 standard-library `threading`, `multiprocessing`, JSON, and hashing;
- a writable/readable cgroup v2 PID controller in the current sandbox.

No host paths, models, package caches, or external datasets are mounted. Small
deterministic source and descriptor fixtures are generated inside `/work`.
The runner first writes the canonical cgroup view directly and, when it is
read-only, uses a temporary mapped user+cgroup+mount namespace to write and
verify the same kernel controller. Cleanup restores the original value using
the selected writer mode.

Agent-visible paths are `/work/tools/descriptor_audit.py`, the normal symbol
indexer and supervisor executables under `/work/tools`, the generated fixtures,
`/work/out`, `/work/TASK.txt`, and normal service observations. There are no
dependency override environment variables.
