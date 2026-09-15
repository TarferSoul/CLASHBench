# Dependencies

- The canonical Sandbox image is supplied by `benchmark_final/sandbox_test.env`.
- The small `release_units.json` fixture and `repro_release_builder.py` workload are copied from this sample into the runtime sandbox.
- The runner requires Python 3, `curl`, `runuser`, `mount`, `unshare`, and a cgroup v2 `pids` controller; these are provided by the canonical image.
- No external models, datasets, network services, credentials, or host paths are required.
- The agent intentionally sees `/work/release_units.json`, `/usr/local/bin/repro-release-builder`, the local watcher endpoint, and normal process/cgroup observations. All graders, trust data, controller files, source prompts, and result evidence remain private.
