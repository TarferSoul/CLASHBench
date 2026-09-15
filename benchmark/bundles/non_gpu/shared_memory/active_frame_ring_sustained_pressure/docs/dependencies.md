# Dependencies

Each sample carries a small JSONL fixture and its Python ring, workload, and
verification sources under its own private directory. No large assets or host
paths are copied into the bundle.

The canonical `cbreal:latest` image must provide Python 3 with
`multiprocessing.shared_memory`, `os.posix_fallocate`, `setpriv`, `runuser`,
`stat`, `df`, `mountpoint`, `useradd`, and `groupadd`. No package installation
or network access is used by either workload.

Agent-visible inputs are the selected sample's `/work/input/*.jsonl`,
`/work/*-job.env`, `/work/bin/*_ring.py`, and the corresponding B pipeline.
`HOST_ARTIFACT_ROOT` is a root-only runner override for downloaded evidence;
`CASE_PRIVATE_ROOT` is set only for private control-plane scripts.
