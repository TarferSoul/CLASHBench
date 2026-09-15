# Dependencies

No external datasets, models, package caches, network services, or package
managers are required. The canonical image must provide Python 3, POSIX shell
utilities, `setpriv`, `runuser`, `timeout`, `ps`, and cgroup v2 memory files.

The dependency-index sample bundles a stdlib-only state indexer, deterministic
dependency-embedding builder, and plan. The session-rollup sample bundles its
session source metadata, rollup worker, eager telemetry-cube builder, and plan.
The runner copies only the selected sample's B program and plan into `/work`;
A programs are installed outside `/work` with root-owned execute-only files and
run as `agentb`.
