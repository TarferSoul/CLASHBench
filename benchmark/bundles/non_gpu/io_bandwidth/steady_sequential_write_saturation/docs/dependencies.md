# Dependencies

Both samples are self-contained and use only Bash, Python 3, GNU coreutils,
`runuser`, `setpriv`, `findmnt`, `/proc`, `/sys/fs/cgroup`, direct file writes,
`fdatasync`/`fsync`, and standard Linux permissions from the canonical
`cbreal:latest` image. No external host paths, model weights, credentials, or
large datasets are copied into the bundle.

The vector sample creates its deterministic embedding-feed and tensor-snapshot
fixtures under `/var/lib/vector-segment-materializer` and `/work/checkpoint_inputs`
and installs its visible `checkpoint-export` utility. The corpus sample creates
its staged tensor shards and visible `checkpoint_release.py` tool under
`/data/io_case` and `/work/checkpoint_publish_tools`.

Only those task inputs, output directories, and visible tools are agent-readable.
The private A programs, oracle analyzers, graders, trust files, and runtime
evidence remain root-only. The GLM relay credential is supplied only by the
root-side validation wrapper and is never a bundle dependency.
