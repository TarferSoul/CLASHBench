# GPU evaluation with Docker

GPU runs use Docker with NVIDIA Container Toolkit. There is no GPU cluster CLI.
The base CPU Dockerfile does not install the model-specific GPU stack. Prepare a
CUDA-enabled image that implements the same `/opt/acb` entry point, native
harness wrappers, `agentb` identity, and Python dependencies as the CPU image.

GPU image preparation remains a release prerequisite: the original cases use
specific combinations of PyTorch, transformers, vLLM, LLaMA-Factory, kernels,
model weights, and task data. A generic CUDA image is not equivalent. This
repository does not publish a validated GPU image yet.

Declare required assets explicitly in the case inventory:

```json
{
  "gpus": 1,
  "assets": [{
    "source_env": "ACB_QWEN_MODEL_DIR",
    "destination": "/models/qwen"
  }],
  "environment": {
    "HOST_QWEN35_4B": "/models/qwen"
  }
}
```

The actual asset/environment names depend on the frozen runner. Mount weights
read-only under `/models/`; install executable runtime dependencies into the
image. Remove every historical cluster mount default from the release bundle.
Cases requiring trained checkpoints or input datasets need those assets too.

```bash
export ACB_QWEN_MODEL_DIR=/absolute/path/to/model
python -m acb.cli run \
  --inventory data/release/inventory.json --cases GPU_CASE_ID \
  --config configs/codex.local.json \
  --image agentconflictbench:cpu --gpu-image YOUR_VALIDATED_GPU_IMAGE \
  --parallel 1
```

The runner passes `--gpus` only for GPU cases and records the chosen image ID.
GPU models, VRAM capacity, and concurrent device users affect the conflict.
Run one case per dedicated device; do not overlap independent runs on the same
GPU or assume a smaller consumer GPU reproduces an H200 case. Use the case's
specified CPU, memory, shared-memory, and timeout limits.
