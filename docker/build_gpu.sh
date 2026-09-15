#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CLASH_LLAMAFACTORY:?Path to the original LlamaFactory checkout}"
: "${CLASH_FASTPATH:?Path to the original Python 3.11 / torch 2.6 fastpath directory}"
: "${CLASH_VLLM:?Path to the original vLLM 0.19.1 environment}"
image=${CLASH_GPU_IMAGE:-clashbench:gpu}
"${CLASH_BUILD_PYTHON:-/usr/bin/python3}" docker/build_gpu_context.py \
  --llamafactory "$CLASH_LLAMAFACTORY" \
  --fastpath "$CLASH_FASTPATH" \
  --vllm "$CLASH_VLLM" \
  | docker build -f docker/Dockerfile.gpu -t "$image" "$@" -
docker run --rm --network none --entrypoint /opt/conda/bin/python \
  "$image" /opt/acb/check_gpu_runtime.py
"${CLASH_BUILD_PYTHON:-/usr/bin/python3}" tests/docker_smoke.py --image "$image"
echo "GPU build, runtime imports, native harnesses, and Docker smoke passed: $image"
