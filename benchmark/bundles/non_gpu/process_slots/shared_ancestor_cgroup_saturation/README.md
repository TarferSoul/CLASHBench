# Shared ancestor cgroup saturation sample

This staged bundle contains one paired A+B sample for the approved
`shared_ancestor_cgroup_saturation` process-slot mechanism. A healthy source
symbol index service and a native SDK ABI matrix run in separate child cgroups
under one bounded cgroup v2 ancestor. The child leaves intentionally report no
finite local PID limit; task creation is charged to the shared ancestor.

Runtime execution is supported only through `bin/run_case.sh` inside a fresh
PJLab Sandbox.
