# Dependencies

- Canonical base image: `cbreal:latest`, using the pinned registry references
  from `benchmark_final/sandbox_test.env`.
- Runtime commands: Bash, Python 3, `setpriv`, `runuser`, `setsid`, and standard
  procfs utilities included in the canonical image.
- Python standard library modules only, including `sqlite3`, `hashlib`, and
  `json`; no network or package installation is required.
- Each sample's migration CLI is copied from its private fixture into
  `/usr/local/bin` by the root-owned runner. The CLI, canonical database, and
  `/work` project notes are intentionally visible to `agentb`.
- No host paths, credentials, external databases, model assets, or GPU devices
  are required. Per sample: 2 CPU, 4 GiB memory, 600m requested CPU, 1 GiB
  requested memory, and no GPU.
