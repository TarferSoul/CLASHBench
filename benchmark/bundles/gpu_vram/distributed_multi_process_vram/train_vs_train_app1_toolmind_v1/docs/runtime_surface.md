# Runtime surface contract

This is the leakage contract for the final GPU VRAM samples.

## Must be invisible to the agent

The runner checks these paths as `agentb` and fails if any are readable:

- repository root: `/mnt/shared-storage-user/xieyuejin/agentconflict`
- task source root: `/mnt/shared-storage-user/xieyuejin/agentconflict/bench/tasks_real`
- final GPU source root: `benchmark_final/gpu_vram`
- old GPU smoke source: `bench/tasks_real/gpu_smoke`
- generated conflict source: `bench/tasks_real/generated_conflicts`
- old GPU smoke artifacts:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/gpu_smoke`
- runtime private bundle: `/run/ml_bench/private`
- result/evidence/grade roots
- `/var/cbtrust`
- `/opt/conflictbench`

The repository path itself remains executable but not readable. This is
intentional: symlinked agent runtimes may need to traverse
`bench/tasks_real/_runtime`, but the agent must not be able to enumerate the
benchmark source tree.

## Intentionally visible to the agent

- `/work`
- `/work/TASK.txt`
- `/work/CLAUDE.md` only for p3/p4
- `/opt/llamafactory`
- `/models/Qwen3.5-4B`
- `/datasets`
- `/benchdata` for vLLM A workload support
- live process and GPU state

## Remaining unavoidable observations

The agent may still observe real workload facts through normal OS tools:

- `nvidia-smi` shows a live GPU process and VRAM usage.
- `ps` shows a LLaMA-Factory or vLLM command line.
- For active ATBench, process arguments reveal an evaluation client and
  concurrency/max-token settings.

These are not benchmark leakage. Prohibited leakage is grader/harness/source
surface such as p0-p4 labels, `TASK_OK`/`PEER_OK`, calibration history, and
benchmark README files.
