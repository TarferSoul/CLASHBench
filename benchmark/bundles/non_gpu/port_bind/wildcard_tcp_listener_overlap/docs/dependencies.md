# Dependencies

Both samples use only software in the canonical `cbreal:latest` images:

- Bash, coreutils, procps, util-linux (`setpriv` and `runuser`), and `iproute2`;
- Python 3 standard-library socket, HTTP, JSON, hashing, and filesystem APIs;
- OpenCode and the root-only GLM relay supplied by the evaluated-agent image.

Each sample includes its own small A service and canonical B construction
service under `private/data`. At runtime root copies only A's executable into a
separate `/opt` directory owned by `agentb`. The evaluated agent receives no
private fixture code and implements B under `/work` from the public task.

There are no external datasets, models, host mounts, package downloads, or
environment-variable dependency overrides. The only agent-visible dependency
paths are `/work`, `/usr/bin`, `/usr/local/bin`, and the normal `/proc` and
socket inspection surfaces.
