# Dependencies

Large assets are not copied into this bundle. The runner creates runtime symlinks to shared storage.

## External shared paths

- `HOST_A_MODEL`: defaults to `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`; exposed as `/models/Qwen3.5-4B`.
- `HOST_B_MODEL`: defaults to `/mnt/shared-storage-gpfs2/gpfs2-shared-public/huggingface/hub/models--Qwen--Qwen3.5-35B-A3B/snapshots/b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6`; exposed as `/models/Qwen3.5-35B-A3B`.
- `HOST_FASTPATH`: defaults to `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`; exposed as `/opt/qwen35_fastpath`.
- `HOST_LLAMAFACTORY`: defaults to `/mnt/shared-storage-user/ai4good1-share/xieyuejin/v1.5AgentDoG/LlamaFactory`; exposed as `/opt/llamafactory` for normal ML tooling imports.
- `HOST_ARTIFACT_ROOT`: defaults to `/mnt/shared-storage-user/ai4good1-share/xieyuejin/agentconflict_artifacts/benchmark_final/gpu_vram`.

## Small bundled fixtures

- Private training rows and validation prompts live under `samples/periodic_eval_batch_vs_qwen35_export_v1/private/data/`.
- Public export request records and the visible export helper live under `samples/periodic_eval_batch_vs_qwen35_export_v1/public/workload/` and are copied to `/work/export_job`.

## Runtime environment

The H200 rjob image must provide:

- Python 3.11 or compatible Python 3
- CUDA-enabled PyTorch
- `transformers`
- `accelerate`
- `peft`
- `safetensors`
- `nvidia-smi`
- standard Unix tools: `bash`, `coreutils`, `find`, `awk`, `sed`, `timeout`

The bundle sets offline model environment variables:

- `HF_HUB_OFFLINE=1`
- `TRANSFORMERS_OFFLINE=1`
- `HF_HOME`, `TRANSFORMERS_CACHE`, and `XDG_CACHE_HOME` under an isolated runtime cache

## Agent-visible dependencies

The evaluated agent may see:

- `/work`
- `/work/TASK.txt`
- `/work/export_job`
- `/models/Qwen3.5-35B-A3B`
- `/models/Qwen3.5-4B`
- `/opt/qwen35_fastpath`
- `/opt/llamafactory`
- ordinary process and GPU telemetry such as `ps` and `nvidia-smi`

The agent must not see the source bundle, private runtime copy, grading scripts, construction logic, trust files, validation ledgers, or result root.
