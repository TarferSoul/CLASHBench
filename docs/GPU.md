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
| vLLM / PyTorch / Transformers | 0.19.1 / 2.10.0+cu128 / 5.13.0 | `/opt/acb-runtime/vllm` |
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

## Use the runtime image

```bash
docker pull ghcr.io/tarfersoul/clashbench:gpu
```

This image contains the training/inference software and native agent tools.
The 10-case GPU inventory and fixtures are bundled with this repository.
Model weights and the two processed training datasets are separate downloads. The bundled CPU quickstart uses the CPU image.

## Maintainer build

The build requires access to the original base image and the three
original runtime directories. Consumers can pull the runtime image; weights
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

The first stage creates the local `clashbench:gpu-runtime` image. After it has
completed, set `CLASH_REUSE_GPU_RUNTIME=1` to retry the final image build without
transferring the runtime again. The final build uses PJLab's Ubuntu Jammy proxy
(`http://mirrors.i.h.pjlab.org.cn/repository/apt-jammy-proxy/ubuntu/`) and forwards
HTTP(S)/NO_PROXY build arguments. PJLab hosts bypass the external proxy, and
apt connects directly to its PJLab mirror. The build requires network access
to PJLab; pass `--build-arg APT_MIRROR=...` to use another Ubuntu mirror outside
the cluster.
Do not reuse the runtime image after changing its source dependencies.

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

See the README's **GPU model downloads** and **GPU task-data downloads**
sections for pinned dataset downloads and checksums. Export the downloaded
directories as `CLASHBENCH_QWEN4B_DIR`, `CLASHBENCH_QWEN35B_DIR`, and `CLASHBENCH_GPU_DATA_DIR` as
needed by the selected case. These must be model/data directories, not Hugging
Face cache roots. Asset mounts are read-only. The CLI checks environment
variables and required metadata/data files before starting its background worker.
It does not verify all model weight shards at this stage.

## Bundled GPU cases

Every case requests one dedicated H200, 32 CPUs, 64000 MiB RAM, and a 1800-second
timeout. Docker shared memory is explicitly 1 GiB (the controller default;
the original index does not specify a separate shared-memory limit).

| Case ID | Models | External task data | Construction oracle |
|---|---|---|---|
| `context_ramp_peak_vs_training_step_v1` | 4B + 35B-A3B | ToolMind | Included |
| `periodic_eval_batch_vs_qwen35_export_v1` | 4B + 35B-A3B | Bundled fixtures only | Included |
| `train_vs_train_app1_toolmind_v1` | 4B | ToolMind + Agentic Safety | Not in original bundle |
| `two_training_tenants_vs_batch_inference_v1` | 4B + 35B-A3B | ToolMind + Agentic Safety | Included |
| `qwen4b_quant_calibration_vs_training_smoke_v1` | 4B | Bundled fixtures only | Included |
| `vllm_qwen4b_continuous_batch_vs_eval_logits_export_v1` | 4B | Bundled fixtures only | Included |
| `checkpointed_code_sft_vs_eval_export_v1` | 4B | Bundled fixtures only | Included |
| `vllm_atbench10_vs_train_toolmind_v1` | 4B + 35B-A3B | ToolMind | Not in original bundle |
| `structured_json_server_vs_quant_eval_v1` | 4B + 35B-A3B | Bundled fixtures only | Included |
| `vllm_idle_vs_train_toolmind_v1` | 4B + 35B-A3B | ToolMind | Not in original bundle |

```bash
python -m clashbench.cli run \
  --inventory benchmark/gpu-inventory.json \
  --cases qwen4b_quant_calibration_vs_training_smoke_v1 \
  --config configs/codex.local.json \
  --gpu-image ghcr.io/tarfersoul/clashbench:gpu --parallel 1
```

Use `--cases all` after downloading all assets. Only the GPU image is needed
for a GPU-only selection. For cases with an included construction oracle,
`--mode oracle` checks construction without an API call and never contributes
to model scores. The three cases without an oracle reject this mode before
launch; they do not silently run an agent. GPU acceptance of the Docker
adapters is pending; see `VALIDATION.md` for the checks completed so far.

## Host GPU requirements

GPU runs use Docker with NVIDIA Container Toolkit. The runner passes `--gpus`
only for GPU cases and records the image ID. The NVIDIA driver must support
both the training CUDA runtime and vLLM's newer CUDA runtime.

GPU model, VRAM capacity, and concurrent users affect the conflict. Run one case
per dedicated device; do not overlap independent runs on the same GPU or assume
a smaller consumer GPU reproduces an H200 case. Use the case's specified CPU,
memory, shared-memory, and timeout limits.
