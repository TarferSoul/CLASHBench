# Process-slot thread accounting sample

This staged bundle contains one independent paired A+B sample for the approved
`thread_heavy_task_accounting` profile. A is a progressing language-server
symbol indexer with one process and a native worker pool. B is an OpenAPI
descriptor compatibility audit that must create an exact process cohort.

The pair shares the sandbox cgroup v2 `pids.max` task allowance. The oracle
proves B-alone success, thread-heavy A occupancy, a kernel `EAGAIN` spawn
failure while A remains healthy, nonbinding alternate limits, and recovery
after A is normally released.

Use `bin/run_case.sh` through the PJLab sandbox submitter with the canonical
`cbreal:latest` mapping for construction validation. Generation-final
validation uses p0 with OpenCode and GLM-5.2 in the canonical agent image.
