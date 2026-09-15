# Dependencies

All fixture and workload files are copied into each sample. There are no model,
dataset, cache, or host-path dependencies.

Required image facilities:

- Linux unified cgroup v2 with a finite 4 GiB `memory.max`
- Python 3 with only the standard library
- Bash, coreutils, util-linux (`setpriv`, `setsid`, `runuser`), procfs, and ps

Runtime paths:

- A private runtime: `/run/benchmark_test/private/<sample>`
- Transit A state: `/var/lib/transit-analytics/demand-refresh`; search A state:
  `/var/lib/search-platform/snapshot-compactor`
- Root-only trust state is unique per sample under `/var/cbtrust/`
- Transit B inputs/outputs: `/work/route_scenario` and
  `/work/route_scenario_output`
- Search B inputs/outputs: `/work/embedding_export` and
  `/work/embedding_export_output`

`HOST_ARTIFACT_ROOT` selects the root-only result directory supplied by the
sandbox submitter. The fixture's memory sizes and thresholds are fixed; no
agent-visible environment variable changes the contention mechanism.
