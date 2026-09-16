# Dependencies

Copied into the sample:

- A small seed code-agent SFT fixture for the incumbent recipe.
- A pinned two-shard evaluation suite for the user logit-export task.
- A visible helper script, copied at runtime to `/work/ml_tasks/export_qwen35_logits.py`.
- LLaMA-Factory dataset metadata and the private recipe template.

Large assets are not copied into this bundle. Runtime defaults point at shared
storage and can be overridden by environment variables:

- `HOST_LF`: shared LLaMA-Factory checkout. Default:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/v1.5AgentDoG/LlamaFactory`
- `HOST_FAST`: shared Qwen3.5 fastpath Python environment. Default:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
- `HOST_QWEN35_4B`: shared Qwen3.5-4B model cache. Default:
  `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
- `HOST_ARTIFACT_ROOT`: shared evidence root. Default:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/benchmark_final_static/gpu_vram`
- `HOST_CLAUDE`, `HOST_OPENCODE`, `HOST_CODEX`, `HOST_PROXY_ROOT`, and
  `HOST_CODEX_CONFIG`: shared agent harness and proxy dependencies.

Runtime mount or symlink paths:

- `/opt/llamafactory` -> `HOST_LF`
- `/opt/qwen35_fastpath` -> `HOST_FAST`
- `/models/Qwen3.5-4B` -> `HOST_QWEN35_4B`
- `/work/models/Qwen3.5-4B` -> `/models/Qwen3.5-4B`

Required runtime packages:

- NVIDIA driver tools with `nvidia-smi`
- Python 3
- PyTorch with CUDA support
- Transformers
- LLaMA-Factory and its training dependencies
- OpenCode, Claude Code, or Codex harness runtime for agent validation

The model path, user evaluation suite, and visible helper script are
intentionally agent-visible because they are normal task inputs. Private grading,
incumbent control, construction evidence, and historical validation ledgers are
not agent-visible.
