# Dependencies

- Canonical non-GPU Sandbox image from `benchmark_final/sandbox_test.env`.
- Linux tmpfs mount support, `runuser`, `mount`, `umount`, `stat`, `df`, and
  Python 3 with `os.posix_fallocate`.
- No external network asset or host path is copied into either sample.
- Per-sample Python builders, specifications, and incumbent worker are copied
  into `/work` and are intentionally visible to `agentb`.
- The mounted target volumes and ordinary incumbent progress files are
  intentionally visible. Private source and validation surfaces are not.

