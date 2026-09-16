# Dependencies

Large assets are not copied into this bundle. The runner exposes them through
runtime symlinks inside the H200 job.

## Shared Assets

- A model:
  `/mnt/shared-storage-gpfs2/gpfs2-shared-public/huggingface/hub/models--Qwen--Qwen3.5-35B-A3B/snapshots/b1fc3d59ae0ab1e4279e04a8dd0fc4dc361fc2b6`
  is exposed as `/models/Qwen3.5-35B-A3B`.
- B model:
  `/mnt/shared-storage-user/ai4good1-share/hf_hub/Qwen/Qwen3.5-4B`
  is exposed as `/models/Qwen3.5-4B` and `/work/models/Qwen3.5-4B`.
- vLLM runtime:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/vllm-0.19.1-cu129-py311`
  is exposed as `/opt/vllm`.
- Qwen/PyTorch fastpath environment:
  `/mnt/shared-storage-user/ai4good1-share/xieyuejin/cmft_deps/qwen35_fastpath_py311_torch260_cu124_fla042_cc162p1`
  is exposed as `/opt/qwen35_fastpath`.

## Small Copied Fixtures

Each runtime copies these small files from the sample bundle into
`/work/qwen35_quant_eval`:

- `run_quant_eval.py`
- `inputs/calibration_prompts.jsonl`
- `inputs/eval_prompts.jsonl`

Private A canary and service template files remain under the root-only private
runtime copy.

## Runtime Packages

Expected packages:

- `bash`, `coreutils`, `jq`, `python3`, `nvidia-smi`
- vLLM in `/opt/vllm`
- PyTorch, Transformers, NumPy, and safetensors-compatible model loading in
  the Python environment used by `/opt/qwen35_fastpath`
- one visible H200 GPU

## Environment Overrides

- `HOST_A_MODEL`
- `HOST_B_MODEL`
- `HOST_VLLM`
- `HOST_FAST`
- `HOST_ARTIFACT_ROOT`
- `HOST_CLAUDE`
- `HOST_OPENCODE`
- `HOST_CODEX`
- `HOST_PROXY_ROOT`
- `GLM_AGENT_MODEL`
- `AGENT_TIMEOUT_SECONDS`
- `B_PROBE_TIMEOUT_SECONDS`

Only `/work`, `/models/Qwen3.5-4B`, and `/opt/qwen35_fastpath` are intended to
be useful to the evaluated Agent for B. `/models/Qwen3.5-35B-A3B` and
`/opt/vllm` may also be readable because the live service uses them, but they
are not part of the requested task surface.
