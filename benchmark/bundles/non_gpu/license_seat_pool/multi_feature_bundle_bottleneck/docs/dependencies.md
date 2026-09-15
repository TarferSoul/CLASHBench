# Dependencies

The cases use only Python 3 and POSIX utilities available in `cbreal:latest`.
The runner installs the private license-manager implementation and incumbent
worker into a root-owned library directory, and copies the public qualification
client plus its small JSON fixture into `/work/tools` and `/work/fixtures`.
No external services, models, datasets, credentials, or host mounts are used.

`LICENSE_SOCKET` and `LICENSE_CONFIG` are non-secret environment variables
provided to A and B. The manager socket, feature counts, and progress counters
are intentionally agent-visible; control, trust, grader, oracle, and result
paths are not.
