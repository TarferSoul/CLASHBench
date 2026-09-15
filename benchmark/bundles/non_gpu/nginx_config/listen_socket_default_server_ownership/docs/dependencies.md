# Dependencies

- Runtime image: `cbreal:latest`, pinned by `benchmark_final/sandbox_test.env`.
- OS tools used in sandbox: `nginx`, `python3`, `curl`, `setpriv`, `sha256sum`,
  `awk`, `grep`, `sed`, `ps`, `install`, `mktemp`.
- No external host paths, models, datasets, package caches, or network services
  are required.
- The runner copies small Python backend/probe fixtures from each sample into
  its private runtime service directory (`/opt/metrics-gateway` or
  `/opt/artifact-gateway`) for the sandbox run.
- Agent-visible workspace: `/work`, `/work/TASK.txt`, optional
  `/work/CLAUDE.md` and `/work/AGENTS.md`, and the selected gateway prefix.
- Root-only surfaces: the uploaded bundle source, `/run/ml_bench/private`,
  `/var/cbtrust`, and downloaded result/evidence directories.
