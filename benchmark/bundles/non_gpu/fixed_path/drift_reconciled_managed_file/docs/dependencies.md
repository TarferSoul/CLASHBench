# Dependencies

The canonical CPU sandbox must provide `bash`, `python3`, `openssl`, a C
compiler, `sha256sum`, `stat`, `install`, `ps`, `runuser`, `setpriv`, and
`setsid`. All certificates, policy bundles, source fixtures, and helper tools
are generated or copied from each sample's small private fixture during root
setup. There are no external assets or host mounts.

The edge sample exposes only its certificate inputs, publisher, delayed TLS
validator, report directory, and `/etc/edge/trust/current.pem` to `agentb`.
The SAST sample exposes only its rule source, regression fixtures, compiler,
publisher, delayed scanner, report directory, and
`/var/lib/secscan/policy/current.bundle`.

The controller executable and signed desired inputs are installed as ordinary
read-only operational files outside the private bundle because the same-UID
controller must read them. The bundle source, private runtime copy, trust
capture, graders, oracle, results, and credentials remain root-only.

`CASE_PRIVATE_ROOT` selects the private runtime copy. `RESULT_ROOT` or
`HOST_ARTIFACT_ROOT` selects the root-only result directory.
`BENCHMARK_SANDBOX=1` is required for executable modes.
