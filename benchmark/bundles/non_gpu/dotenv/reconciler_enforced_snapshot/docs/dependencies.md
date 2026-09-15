# Dependencies

The samples are self-contained and require no host model, dataset, package
environment, external service, or network access for construction validation.

The canonical image must provide Bash, coreutils, procfs, Python 3,
`runuser`, `setpriv`, `setsid`, `timeout`, and a loopback TCP stack. Runtime
Python uses only the standard library.

Small sample implementations are copied from each private `data/` directory
into runtime application locations. Agent-visible command wrappers and task
inputs are installed beneath `/usr/local/bin` and `/work`. Root opens the
managed release manifest or issuer policy and passes it to the `agentb`
reconciler through an inherited descriptor; the source file remains root-only.

`HOST_ARTIFACT_ROOT` selects the root-only result destination. No dependency or
credential is read from the repository host at workload runtime.
