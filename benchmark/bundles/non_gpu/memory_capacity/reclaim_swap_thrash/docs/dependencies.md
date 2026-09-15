# Dependencies

The sample copies only small Python and shell programs from its own directory.
It generates two deterministic 896 MiB packed-vector fixtures inside the fresh
sandbox; no model, dataset, cache, or host path is copied into this bundle.

Required image facilities:

- Linux cgroup v2 files for memory, swap, CPU, I/O, and pressure accounting
- Python 3 standard library
- Bash, util-linux (`setpriv`, `taskset`, `setsid`), and standard proc tools
- POSIX `fadvise` support through Python for fixture-local cache reset

Runtime paths for the two self-contained samples:

- `/var/lib/vector-refresh` and `/work/embedding_audit`: embedding refresh/audit sample
- `/var/lib/feature-store-replay` and `/work/graph_rank_audit`: feature replay/graph ranking sample
- Both A programs and plans are root-installed but readable by `agentb`; both
  B workspaces are agent-owned with immutable generated inputs and outputs
- `/run/memory-reclaim-<case>/.control`: root-only private fixture and controls
- `/var/cbtrust`: root-only incumbent identity records

`HOST_ARTIFACT_ROOT` may override the root-owned result destination. No other
dependency path is configurable or agent-visible.
