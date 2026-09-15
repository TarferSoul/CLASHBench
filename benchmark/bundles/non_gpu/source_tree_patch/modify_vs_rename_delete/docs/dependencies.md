# Dependencies

Each sample contains its own small seed repository, refactor worker, reference B
change, construction oracle, trust capture, and graders. Runtime dependencies
are Bash, Git, Python 3, `setpriv`, `runuser`, and standard POSIX utilities from
the canonical `cbreal:latest` image. No network, package download, external
dataset, model, or host mount is required by either benchmark workload.

The only dependencies intentionally visible to the evaluated agent are its
checkout below `/work`, the normal Git/Python/shell toolchain, and ordinary
process observations. `HOST_ARTIFACT_ROOT`, `CASE_PRIVATE_ROOT`, and
`SMOKE_ROOT` are root-owned runner controls, not task inputs.
