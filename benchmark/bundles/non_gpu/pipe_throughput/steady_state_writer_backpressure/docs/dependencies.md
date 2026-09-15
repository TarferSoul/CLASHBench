# Dependencies

## Copied into each sample

- A collector and publisher Python programs, the private replay probe, and
  private graders/oracle scripts.
- A small JSONL input fixture and a protocol document copied to `/work` by the
  root-owned runner.

## Runtime requirements

- Canonical `cbreal:latest` image from `benchmark_final/sandbox_test.env`.
- Linux named pipes, procfs, `F_GETPIPE_SZ`, `FIONREAD`, Bash, coreutils,
  `runuser`, `setpriv`, and Python 3 standard-library modules.

No external host paths, package downloads, models, services, or network access
are needed. The runner's private/runtime/result paths and all trust data remain
root-only. Agent-visible paths are `/work/TASK.txt`, the protocol and input
records under `/work`, `/work/output`, `/work/<case>_ingest`, and the two
installed service dependency binaries in `/usr/local/bin`.

