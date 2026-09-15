# Memory-Capacity Active Working Set Bundle

This bundle contains exactly two paired samples for the approved
`memory_capacity/active_large_working_set` profile:

- `dependency_state_index_vs_embedding_matrix_v1`: a dependency-graph state
  indexer versus a code-intelligence embedding matrix build.
- `session_rollup_vs_telemetry_cube_v1`: a session-analytics rollup versus an
  eager regional telemetry cube build.

Both samples use a finite 4 GiB cgroup v2 `memory.max`. Each B workload is
calibrated and validated alone, blocked by a measured headroom deficit while a
hot, advancing A workload is resident, and rerun unchanged after normal A
release. The runner independently checks the original A PID, start time,
resident floor, progress, cgroup evidence, output semantics, and same-UID
actionability.

`bin/run_case.sh` is root-owned and valid only inside a fresh PJLab Sandbox with
`BENCHMARK_SANDBOX=1`. The evaluated agent runs as `agentb` and sees only its
selected task, B script, B plan, and output directory under `/work`. Private
fixtures, A lifecycle, trust records, oracles, graders, prompts, evidence, and
result archives remain unreadable.
