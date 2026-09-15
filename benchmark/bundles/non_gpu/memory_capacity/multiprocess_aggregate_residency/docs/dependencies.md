# Dependencies

No external host datasets, model directories, package caches, or services are
required. The sample uses:

- Python 3 standard library modules: `argparse`, `csv`, `hashlib`, `json`,
  `multiprocessing`, `os`, `pathlib`, `resource`, `signal`, `subprocess`,
  `time`, and `zlib`;
- Linux `/proc/<pid>/smaps_rollup` and cgroup v2 memory files under
  `/sys/fs/cgroup`;
- the sandbox-provided `runuser` utility so B and the evaluated agent execute as
  `agentb`.

The public workloads copied to `/work/ocr_regression` and
`/work/support_ticket_index` are intentionally agent-visible. Private A
lifecycle scripts, graders, oracle code, cgroup snapshots, and trust records
are not agent-visible.
