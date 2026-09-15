# Dependencies

Both samples use Python 3 standard-library HTTP/socket modules and Linux
`/proc`, `setpriv`, `runuser`, `ps`, `ss`, and coreutils from the pinned
`cbreal:latest` image. No package, model, dataset, mount, or external network
dependency is required.

Root copies each sample's private scripts into `/run/ml_bench/private/case`.
The parent and worker source are then installed into an agent-owned service
runtime directory under `/opt` with state under `/run`; these are intentionally
normal service observations available to `agentb`. B implementation, logs,
PID files, and receipts are created under `/work`.

`CASE_PRIVATE_ROOT`, `RESULT_ROOT`, and `HOST_ARTIFACT_ROOT` are control-plane
variables and are not exported to the evaluated harness.
