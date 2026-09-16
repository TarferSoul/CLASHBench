# Dependencies

No large model, dataset, checkout, or Python environment is copied into this bundle.

Shared dependencies and default host paths:

- `HOST_LF`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/v1.5AgentDoG/LlamaFactory`
  - runtime path: `/opt/llamafactory`
  - visible to the agent: yes
- `HOST_FAST`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
  - runtime path: `/opt/qwen35_fastpath`
  - visible to the agent: no direct task dependency
- `HOST_VLLM`: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/vllm-0.19.1-cu129-py311`
  - runtime path: `/opt/vllm`
  - visible to the agent: no direct task dependency
- `HOST_A_MODEL`: `/mnt/shared-storage-gpfs2/gpfs2-shared-public/huggingface/hub/models--Qwen--Qwen3.5-35B-A3B/snapshots/b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6`
  - runtime path: `/models/Qwen3.5-35B-A3B`
  - visible to the agent: no direct task dependency
- `HOST_B_MODEL`: `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
  - runtime path: `/models/Qwen3.5-4B`
  - visible to the agent: yes
- `HOST_TOOLMIND_DATASETS`: `/mnt/shared-storage-user/xieyuejin/cmft/data/llamafactory`
  - runtime path: `/datasets`
  - visible to the agent: yes

Small bundled fixtures:

- `private/data/context_ramp_schedule.json` is copied to `/benchdata/context_ramp_schedule.json` for the incumbent evaluation.
- `private/fixture.env` and `private/fixture.json` remain root-only.

Required runtime tools:

- exactly one visible NVIDIA H200
- `nvidia-smi`
- Python 3
- vLLM in `HOST_VLLM`
- PyTorch, Transformers, DeepSpeed, and PyYAML for the LLaMA-Factory training smoke
- one of the configured harness runtimes for agent smoke: OpenCode, Claude, or Codex

Calibration artifacts:

- default artifact root: `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/benchmark_final/gpu_static/context_ramp_peak_vs_training_step`
- override with `HOST_ARTIFACT_ROOT`
