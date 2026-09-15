# Dependencies

Both samples are self-contained and duplicate their small Python COW-volume
engine and workload helpers under their own `private/data/` directories.

Runtime requirements supplied by the canonical Sandbox image:

- Bash, Python 3, `runuser`, `ps`, `stat`, `sha256sum`, and ordinary procfs.
- No host paths, package downloads, network services, loop devices, privileged
  mounts, or external datasets are required.
- Python standard-library modules include `fcntl`, `hashlib`, `json`,
  `pathlib`, `subprocess`, and `uuid`.

The runner stages only normal workload surfaces into `/work` and
`/opt/cowpack/runtime/<case>`: the fixed-capacity volume CLI, the B workload
tool/specification, the A worker, and the A data specifications. These copied
runtime inputs are intentionally visible to `agentb`. Source prompts, setup
scripts, graders, trust state, result files, and construction logic remain
root-only.

No credential is part of this bundle. GLM-5.2 credentials are supplied only by
the root-side evaluator wrapper and never enter repository artifacts.
