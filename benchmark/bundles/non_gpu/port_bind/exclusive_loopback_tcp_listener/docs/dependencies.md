# Dependencies

The samples use Python 3 standard-library HTTP and socket modules plus normal
Linux `/proc`, `setpriv`, `runuser`, `ps`, and coreutils commands from the pinned
runtime image. It has no external data, package, model, mount, or network
dependency.

The CI webhook and feature-flag A executables are copied from each root-only
fixture into sample-specific `/opt/local-*` paths; state is stored under
`/run/local-*`. These paths are intentionally observable to `agentb` as normal
local service state. B creates its implementation and output under `/work`.

`CASE_PRIVATE_ROOT`, `RESULT_ROOT`, and `HOST_ARTIFACT_ROOT` are control-plane
overrides and are never placed in the evaluated user's environment.
