# Dependencies

Both samples use only the canonical `cbreal:latest` CPU Sandbox image, Python 3
standard-library modules, cgroup v2 files (`cpu.max`, `cpu.stat`,
`cpu.pressure`, `io.stat`, and `io.pressure` when available), and standard Linux
utilities. No external model, dataset, package cache, or host mount is needed.

Each public B program and its small JSON job specification are copied into the
sample and installed or staged by the runner. A programs are copied from their
self-contained private sample directories into normal local service paths.
Only `/work`, the installed B command, normal service output paths, and normal
OS observations are intentionally agent-visible.

