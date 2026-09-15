# Dependencies

The sample has no downloaded model, browser, package, or external-service
dependency. It uses only Python 3 standard-library modules available in the
canonical `cbreal:latest` image:

- `multiprocessing.shared_memory`, `multiprocessing`, `http.server`,
  `hashlib`, `csv`, and `json`;
- Linux `/dev/shm` tmpfs accounting via `statvfs` and `st_blocks`;
- `bash`, `df`, `ps`, `stat`, `runuser`, and `setsid`.

The small CSV under `private/data/tile_features.csv` is copied to
`/work/input/tile_features.csv` for a task run and is intentionally visible as
normal task input. The runner copies only A's executable to
`/run/benchmark_test/a_runtime/a/tile_service.py`; this ordinary runtime copy is
agent-readable, while its state directory and all oracle, trust, grader, and
source files remain private.

The runner sets `SMOKE_ROOT` to the root-only private fixture copy,
`RESULT_ROOT` to the root-only result directory, `A_RUNTIME_ROOT` to
`/run/benchmark_test/a_runtime`, and `A_STATE_ROOT` to that same runtime root.
These environment variables select in-Sandbox paths only; none points to a host
dependency. B receives only `/work/input` and `/work/output` as task-visible
data paths.
