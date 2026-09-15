# Dependencies

- Canonical base image: `cbreal:latest`, pinned by `benchmark_final/sandbox_test.env`.
- Required image commands: Bash, Python 3, `mount`, `umount`, `unshare`,
  `findmnt`, `df`, `du`, `runuser`, `ps`, `stat`, and `sha256sum`.
- Each sample copies its small Python fixture and publisher implementations into
  the private Sandbox bundle. No external dataset, model, package download, or
  network service is required.
- The runner creates a fresh project directory under the canonical image's
  pre-mounted `/dev/shm` tmpfs. The fixture records that kernel-accounted domain
  and its available capacity; `/` remains a separate filesystem with irrelevant
  free headroom. No new mount capability is required.
- Agent-visible dependencies are the seeded project tree, its B publisher under
  `tools/`, Python 3, and ordinary OS inspection commands. Private A helpers,
  trust files, graders, construction checks, and results are intentionally not
  visible.
