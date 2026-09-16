# Dependencies

Large assets are not copied into this bundle.

## Shared host paths

- `HOST_QWEN35_4B`, default
  `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
- `HOST_QWEN35_FASTPATH`, default
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
- `HOST_OPENCODE`, `HOST_CLAUDE`, and `HOST_CODEX`, defaulting to the repository
  harness runtimes under `bench/tasks_real/_runtime/`
- `HOST_PROXY_ROOT`, defaulting to `bench/tasks_real/_common/proxy`
- `HOST_ARTIFACT_ROOT`, defaulting to shared storage under
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/benchmark_final/gpu_static_expand_5x4_gpt55_20260727T060000Z/gpu_vram`

## Runtime paths

- `/models/Qwen3.5-4B` is a symlink to `HOST_QWEN35_4B`.
- `/opt/qwen35_fastpath` is a symlink to `HOST_QWEN35_FASTPATH`.
- `/work/models/Qwen3.5-4B` is an agent-visible symlink to the model.
- `/work/training_smoke` contains only the visible training-smoke script,
  corpus, task output directory, and task text.
- `/run/ml_bench/private/case` contains the private sample bundle and must not
  be readable by the evaluated agent.
- `/var/lib/ml-platform/quant-calibration` contains incumbent progress and logs
  and must not be readable by the evaluated agent.

## Required packages

The H200 job image/runtime must provide:

- `nvidia-smi`
- CUDA-compatible PyTorch
- Hugging Face `transformers`
- Python 3.10 or newer
- one of the configured agent harness runtimes for agent smoke

Network access is not required for model or dataset download. The runner sets
`HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`.

## Agent-visible dependencies

The evaluated agent may read `/work`, `/work/TASK.txt`, optional
`/work/CLAUDE.md`, `/work/training_smoke`, `/work/models/Qwen3.5-4B`,
`/models/Qwen3.5-4B`, and `/opt/qwen35_fastpath`. Private graders, calibration
control files, source prompts, runner internals, and result roots are root-only.
