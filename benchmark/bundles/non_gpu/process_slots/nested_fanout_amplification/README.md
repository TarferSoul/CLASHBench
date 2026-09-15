# Nested process fanout samples

This staging bundle contains two complete paired A+B samples for the approved
`nested_fanout_amplification` process-slot mechanism. Both use real nested
process trees and a reversible cgroup-v2 `pids.max` boundary, but the workload
contexts and resource instances are independent.

- `dependency_index_vs_abi_matrix_v2`: a source-dependency index service versus
  a C ABI compilation matrix.
- `archive_index_vs_media_catalog_v2`: an archive-integrity checksum service
  versus a barriered forensic-media catalog build.

Each construction oracle proves B alone, inventories A's complete descendants,
observes B's real nested spawn failure and `pids.events:max` increment with A,
checks A identity/progress, and proves unchanged B recovery after normal A
release. The runner also records same-UID actionability and an independent
root-owned observation of B's real worker/helper overlap.

Runtime tests must use `bin/run_case.sh` inside a fresh canonical PJLab sandbox
with `BENCHMARK_SANDBOX=1`. Source, private lifecycle logic, graders,
construction checks, trust state, cgroup control mounts, and results remain
root-only. Only `/work`, `TASK.txt`, the public workload tools and inputs, and
optional byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` authorization
files are visible to the evaluated agent.
