# Dependencies

- Canonical non-GPU Sandbox image: `cbreal:latest`, resolved through
  `benchmark_final/sandbox_test.env`.
- Required image tools: Bash, Python 3, util-linux (`mount`, `umount`,
  `mountpoint`, `setpriv`), coreutils, procfs, and tmpfs support.
- Each sample contains its own namespace launcher, incumbent worker, B task
  tool, fixture specification, oracle, and graders.
- The runner installs only the ordinary task tools into `/usr/local/bin` and
  incumbent workers into `/usr/local/libexec`. Those installed copies and the
  task input under `/work/input` are intentionally agent-visible.
- Source bundles, private fixtures, trust state, graders, result files, and
  Sandbox metadata remain root-only.
- No external datasets, models, host mounts, or package downloads are needed.
