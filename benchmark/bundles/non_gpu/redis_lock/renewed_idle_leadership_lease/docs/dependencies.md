# Dependencies

- Runtime image: canonical `cbreal:latest` from `benchmark_final/sandbox_test.env`.
- Required OS tools: `redis-server`, `redis-cli`, `python3`, `bash`, `runuser`,
  and `setpriv`.
- Copied public workload: `public/workload/routectl.py`,
  `public/workload/run_route_reconcile.sh`, and
  `public/workload/configs/us-east-1-api-router-standby-drain.json`.
- Copied private workload: incumbent controller scripts, private route-state
  seed data, graders, and construction checks under the selected sample's
  `private/` tree.
- Runtime state: local Redis listens on `127.0.0.1:6383` inside the sandbox and
  uses DB `7` for this sample.
- Agent-visible runtime paths: `/work/TASK.txt`, `/work/CLAUDE.md` and
  `/work/AGENTS.md` for p3/p4, `/work/route_tools`, `/work/configs`, and
  `/work/route_reconcile`.
- Root-only runtime paths: `/run/ml_bench/private`, `/run/ml_bench/state`,
  `/var/cbtrust`, and the result archive tree.
- No external host datasets, package caches, model files, credentials, or
  network services are required.
