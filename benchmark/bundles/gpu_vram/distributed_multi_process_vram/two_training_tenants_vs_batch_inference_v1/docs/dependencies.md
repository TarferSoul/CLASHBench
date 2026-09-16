# Dependencies

This bundle keeps large assets on shared storage and exposes them through
runtime symlinks.

Shared host paths used by default:

- `HOST_LF=/mnt/shared-storage-user/ai4good1-share/xieyuejin/v1.5AgentDoG/LlamaFactory`
- `HOST_FAST=/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
- `HOST_QWEN4B=/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
- `HOST_QWEN35B=/mnt/shared-storage-gpfs2/gpfs2-shared-public/huggingface/hub/models--Qwen--Qwen3.5-35B-A3B/snapshots/b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6`
- `HOST_APP1_DATA=/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/static_data/gpu_smoke/train_vs_train_app1_toolmind_v1/data/agentic_safety_sft.json`
- `HOST_TOOLMIND_DATA=/mnt/shared-storage-user/xieyuejin/cmft/data/llamafactory/toolmind_fullfilter50k_direct_plain_train.json`

Runtime symlinks:

- `/opt/llamafactory` points to `HOST_LF`
- `/opt/qwen35_fastpath` points to `HOST_FAST`
- `/models/Qwen3.5-4B` points to `HOST_QWEN4B`
- `/models/Qwen3.5-35B-A3B` points to `HOST_QWEN35B`
- `/datasets` points to a small runtime directory containing `dataset_info.json`
  and symlinks to the two shared training datasets

Agent-visible dependencies:

- `/work/models/Qwen3.5-35B-A3B`
- `/work/models/Qwen3.5-4B`
- `/work/datasets`
- `/work/inputs/qwen_batch_requests.jsonl`
- `/work/tools/export_qwen_batch.py`

Required runtime packages:

- CUDA runtime and `nvidia-smi`
- Python 3 with `torch`, `transformers`, `accelerate`, `yaml`, and
  LLaMA-Factory requirements
- Harness runtimes for `claude`, `opencode`, or `codex` when running agent
  smoke validation

Override paths with the environment variables listed above. Runtime artifacts
default to `HOST_ARTIFACT_ROOT`, under shared storage.
