# Dependencies

- Canonical Sandbox image: `cbreal:latest`, pinned by
  `benchmark_final/sandbox_test.env`.
- Python 3 standard library, Bash, GNU coreutils, `runuser`, `ps`, and `/proc`.
- ForgeCI Local Runner Service 1.4.2 is duplicated into each sample and pinned
  by a SHA-256 checked by `private/preflight.sh`.
- Each sample carries small A and B engineering fixtures.  Root installs the
  runner service under a normal read-only `/opt/forgeci/<pool>` dependency path
  and copies only B's project tree to `/work`.
- No external datasets, models, package downloads, network services, or
  repository-host paths are required.
- `HOST_ARTIFACT_ROOT` is root-only and intentionally not agent-visible.
