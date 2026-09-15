# GPU evaluation with Docker

## Packaged runtime

`docker/Dockerfile.gpu` packages the original training and inference runtimes,
plus the same native agent tools and `/opt/acb` entry point as the CPU image.
No model weights or task datasets are added by the GPU build context.

| Component | Packaged version | Container path |
|---|---|---|
| Training Python / PyTorch | 3.11.11 / 2.6.0+cu124 | `/opt/conda` |
| Transformers / DeepSpeed | 5.6.0 / 0.18.4 | Training environment |
| LlamaFactory | `f28afaf6355af515454dfb16c97d728307c93897` with local source changes recorded by file hashes | `/opt/acb-runtime/llamafactory` |
| FLA / causal-conv1d | 0.4.2 / 1.6.2.post1 | `/opt/acb-runtime/fastpath` |
| vLLM / PyTorch / Transformers | 0.19.1 / 2.10.0 / 5.13.0 | `/opt/acb-runtime/vllm` |
| Codex / Claude Code / OpenCode | 0.154.0 / 2.1.272 / 1.18.31 | `/opt/harness` |

The agent versions match this repository's portable CPU runtime. They are not
claimed to match every original paper run. The original training environment
uses `DISABLE_VERSION_CHECK=1`; this is retained because its Transformers 5.6.0
version falls outside the newer LlamaFactory checkout's declared constraints.

The vLLM environment is separate: run it with `/opt/vllm/bin/python` and remove
training `PYTHONPATH` entries (`env -u PYTHONPATH /opt/vllm/bin/python ...`).
Do not upgrade the training environment to vLLM's PyTorch version.

`/opt/llamafactory`, `/opt/qwen35_fastpath`, and `/opt/vllm` are compatibility
links. The `HOST_LF`, `HOST_FAST`, `HOST_FASTPATH`, and `HOST_VLLM` environment
variables point to distinct packaged source directories so a case can recreate
these links without deleting the installed source. Native agent adapters remain
under `/opt/node/bin` and `/usr/local/bin`.

## Maintainer build

The build currently requires access to the original base image and the three
original runtime directories. Consumers will use the published image; weights
and task data are downloaded independently as described in the README.

```bash
export CLASH_LLAMAFACTORY=/absolute/path/to/LlamaFactory
export CLASH_FASTPATH=/absolute/path/to/qwen35_fastpath
export CLASH_VLLM=/absolute/path/to/vllm-0.19.1-environment
bash docker/build_gpu.sh > gpu-build.log 2>&1 &
echo "Build PID: $!"
```

`build_gpu_context.py` streams a restricted file selection directly into Docker
instead of duplicating a large environment on disk. It includes tracked
LlamaFactory source/configuration files, the fastpath packages, and vLLM's
site-packages/Python executables. It excludes the LlamaFactory data directory,
model checkpoints, experiment outputs, credentials, caches, and Git metadata.
It rejects external or absolute symlinks and writes file hashes plus the
LlamaFactory commit to `/opt/acb-runtime/manifest.json`. The copied Python venv
metadata uses container paths rather than the original cluster path.

The default base is pinned by digest in the Dockerfile. `--build-arg GPU_BASE=...`
can select a relocated copy of that exact image. A public base replacement has
not been validated.

Validate the installed software without models, data, or a GPU:

```bash
docker run --rm --network none --entrypoint /opt/conda/bin/python \
  clashbench:gpu /opt/acb/check_gpu_runtime.py
python tests/docker_smoke.py --image clashbench:gpu
```

These checks cover imports, environment separation, native tool startup, and
Docker orchestration. They do not establish CUDA-kernel or benchmark-case
correctness; those checks require a dedicated GPU and the external assets.

## Download and mount assets

See the README's separate **GPU model downloads** and **GPU task-data
downloads** sections. A case that needs both models and the training data can
include these entries in its inventory:

```json
{
  "gpus": 1,
  "assets": [
    {"source_env": "ACB_QWEN4B_DIR", "destination": "/models/qwen4b"},
    {"source_env": "ACB_QWEN35B_DIR", "destination": "/models/qwen35b"},
    {"source_env": "ACB_GPU_DATA_DIR", "destination": "/models/gpu-tasks"}
  ],
  "environment": {
    "HOST_B_MODEL": "/models/qwen4b",
    "HOST_QWEN35_4B": "/models/qwen4b",
    "HOST_A_MODEL": "/models/qwen35b",
    "HOST_A_SERVICE_MODEL": "/models/qwen35b",
    "HOST_TOOLMIND_DATASETS": "/models/gpu-tasks",
    "HOST_APP1_STATIC_DATA": "/models/gpu-tasks"
  }
}
```

Use only the assets required by the selected case. The directory names refer to
normal downloaded model directories, not Hugging Face cache roots. The CLI
mounts assets read-only. Full frozen-case exports still need their Docker
adapter: legacy runners that overwrite agent wrappers or start internal API
proxies must be ported as described in `DATASET.md` before model evaluation.
The runtime image alone does not convert those runners.

```bash
python -m acb.cli run \
  --inventory data/release/inventory.json --cases GPU_CASE_ID \
  --config configs/codex.local.json \
  --image agentconflictbench:cpu --gpu-image clashbench:gpu \
  --parallel 1
```

## Host GPU requirements

GPU runs use Docker with NVIDIA Container Toolkit. The runner passes `--gpus`
only for GPU cases and records the image ID. The NVIDIA driver must support
both the training CUDA runtime and vLLM's newer CUDA runtime.

GPU model, VRAM capacity, and concurrent users affect the conflict. Run one case
per dedicated device; do not overlap independent runs on the same GPU or assume
a smaller consumer GPU reproduces an H200 case. Use the case's specified CPU,
memory, shared-memory, and timeout limits.
