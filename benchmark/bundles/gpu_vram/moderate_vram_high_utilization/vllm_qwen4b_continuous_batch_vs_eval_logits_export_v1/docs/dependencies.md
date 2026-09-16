# Dependencies

No large model, dataset, vLLM checkout, LLaMA-Factory checkout, Python
environment, cache, or result archive is copied into this bundle.

## Shared host paths

Defaults can be overridden by environment variables in the one-H200 rjob entry
script:

- `HOST_VLLM`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/vllm-0.19.1-cu129-py311`
- `HOST_QWEN35_FASTPATH`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
- `HOST_QWEN35_4B`: `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
- `HOST_OPENCODE`: `<repo>/bench/tasks_real/_runtime/opencode`
- `HOST_CLAUDE`: `<repo>/bench/tasks_real/_runtime/claude_code`
- `HOST_CODEX`: `<repo>/bench/tasks_real/_runtime/codex`
- `HOST_PROXY_ROOT`: `<repo>/bench/tasks_real/_common/proxy`
- `HOST_CODEX_CONFIG`: `<repo>/bench/tasks_real/_common/codex_config.toml`
- `HOST_ARTIFACT_ROOT`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/benchmark_final/gpu_static_expand_5x4_gpt55_20260727T060000Z/gpu_vram`

## Runtime symlinks and installed assets

- `/models/Qwen3.5-4B` links to `HOST_QWEN35_4B`.
- `/opt/vllm` links to `HOST_VLLM`.
- `/opt/qwen35_fastpath` links to `HOST_QWEN35_FASTPATH`.
- `/work/models/Qwen3.5-4B` links to `/models/Qwen3.5-4B`.
- `/work/eval_export/eval_export_logits.py` is copied from this sample's
  public workload assets and is intentionally agent-visible.
- `/work/eval_export/requests.jsonl` is copied from this sample's public
  workload assets and is intentionally agent-visible.
- A's deterministic request set is copied from private data to
  `/var/lib/ml-platform/jobs/qwen35_4b_batch_service/current/requests.jsonl`;
  it is normal service runtime state, not grader logic.

## Required software

- one visible NVIDIA H200 and `nvidia-smi`
- CUDA-capable PyTorch with Transformers
- vLLM compatible with the Qwen3.5-4B model
- Python standard library modules used by the runner and helpers
- one of the configured agent harnesses: `opencode`, `claude`, or `codex`

The static generation pass only checks shell syntax, JSON parseability, prompt
identity, source leakage patterns, and path containment. Real-H200 calibration
is pending.

