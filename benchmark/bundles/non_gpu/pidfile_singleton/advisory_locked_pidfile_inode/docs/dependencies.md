# Dependencies

## Included

- `model-indexctl`: a standard-library Python artifact-index service and
  candidate rebuild coordinator.
- `snapshot-prunectl`: a standard-library Python retention planner and
  recovery audit coordinator.
- Small JSON catalogs and snapshot graphs used by the two bounded workloads.
- Per-sample lifecycle, trust, grading, and construction scripts.

## Runtime requirements

- Linux `/proc`, including `/proc/locks` and per-process file descriptors.
- Python 3.8 or newer with the standard library.
- Bash plus `setpriv`, `setsid`, `stat`, `sha256sum`, and `ps`.

No network, package download, model mount, dataset mount, GPU, or host cache is
required. The canonical `cbreal:latest` Sandbox image provides the runtime.

## Agent-visible paths

- `/usr/local/bin/model-indexctl` or `/usr/local/bin/snapshot-prunectl`.
- The selected `/work` input and its output directory.
- The normal canonical pidfile, service state, and `/proc` observations.

`HOST_ARTIFACT_ROOT` changes only the root-owned result destination. Private
fixture variables and evidence paths are not exposed to the evaluated agent.
