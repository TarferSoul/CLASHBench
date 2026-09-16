# GPU evaluation with Docker

## Packaged runtime

`docker/Dockerfile.gpu` packages the original training and inference runtimes,
plus the same native agent tools and `/opt/acb` entry point as the CPU image.
No model weights or task datasets are added by the GPU build context.

| Component | Packaged version | Container path |
|---|---|---|
| Training Python / PyTorch | 3.11.11 / 2.6.0+cu124 | `/opt/conda` |
| Transformers / DeepSpeed | 5.6.0 / 0.18.4 | Training environment |
| LlamaFactory | `f28afaf6355af515454dfb16c97d728307c93897` | `/opt/acb-runtime/llamafactory` |
| FLA / causal-conv1d | 0.4.2 / 1.6.2.post1 | `/opt/acb-runtime/fastpath` |
| vLLM / PyTorch / Transformers | 0.19.1 / 2.10.0+cu128 / 5.13.0 | `/opt/acb-runtime/vllm` |
| Codex / Claude Code / OpenCode | 0.154.0 / 2.1.272 / 1.18.31 | `/opt/harness` |

The training environment uses `DISABLE_VERSION_CHECK=1`; this is retained because its Transformers 5.6.0
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
timeout. Docker shared memory is explicitly 1 GiB.

| Case ID | Models | External task data |
|---|---|---|
| `context_ramp_peak_vs_training_step_v1` | 4B + 35B-A3B | ToolMind |
| `periodic_eval_batch_vs_qwen35_export_v1` | 4B + 35B-A3B | Bundled fixtures only |
| `train_vs_train_app1_toolmind_v1` | 4B | ToolMind + Agentic Safety |
| `two_training_tenants_vs_batch_inference_v1` | 4B + 35B-A3B | ToolMind + Agentic Safety |
| `qwen4b_quant_calibration_vs_training_smoke_v1` | 4B | Bundled fixtures only |
| `vllm_qwen4b_continuous_batch_vs_eval_logits_export_v1` | 4B | Bundled fixtures only |
| `checkpointed_code_sft_vs_eval_export_v1` | 4B | Bundled fixtures only |
| `vllm_atbench10_vs_train_toolmind_v1` | 4B + 35B-A3B | ToolMind |
| `structured_json_server_vs_quant_eval_v1` | 4B + 35B-A3B | Bundled fixtures only |
| `vllm_idle_vs_train_toolmind_v1` | 4B + 35B-A3B | ToolMind |

```bash
python -m clashbench.cli run \
  --inventory benchmark/gpu-inventory.json \
  --cases qwen4b_quant_calibration_vs_training_smoke_v1 \
  --config configs/codex.local.json \
  --gpu-image ghcr.io/tarfersoul/clashbench:gpu --parallel 1
```

Use `--cases all` after downloading all assets. Only the GPU image is needed
for a GPU-only selection.

## Host GPU requirements

GPU runs use Docker with NVIDIA Container Toolkit. The runner passes `--gpus`
only for GPU cases and records the image ID. The NVIDIA driver must support
both the training CUDA runtime and vLLM's newer CUDA runtime.

GPU model, VRAM capacity, and concurrent users affect the conflict. Run one case
per dedicated device; do not overlap independent runs on the same GPU or assume
a smaller consumer GPU reproduces an H200 case. Use the case's specified CPU,
memory, shared-memory, and timeout limits.
