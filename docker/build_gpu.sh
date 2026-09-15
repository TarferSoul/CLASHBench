#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
image=${CLASH_GPU_IMAGE:-clashbench:gpu}
runtime_image=${CLASH_GPU_RUNTIME_IMAGE:-clashbench:gpu-runtime}
if [ "${CLASH_REUSE_GPU_RUNTIME:-0}" != 1 ]; then
  : "${CLASH_LLAMAFACTORY:?Path to the original LlamaFactory checkout}"
  : "${CLASH_FASTPATH:?Path to the original Python 3.11 / torch 2.6 fastpath directory}"
  : "${CLASH_VLLM:?Path to the original vLLM 0.19.1 environment}"
  "${CLASH_BUILD_PYTHON:-/usr/bin/python3}" docker/build_gpu_context.py \
    --llamafactory "$CLASH_LLAMAFACTORY" \
    --fastpath "$CLASH_FASTPATH" \
    --vllm "$CLASH_VLLM" \
    | docker build -f docker/Dockerfile.gpu-runtime -t "$runtime_image" -
fi
docker build -f docker/Dockerfile.gpu --build-arg GPU_RUNTIME_IMAGE="$runtime_image" \
  --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg http_proxy --build-arg https_proxy \
  --build-arg NO_PROXY --build-arg no_proxy \
  -t "$image" "$@" .
docker run --rm --network none --entrypoint /opt/conda/bin/python \
  "$image" /opt/acb/check_gpu_runtime.py
"${CLASH_BUILD_PYTHON:-/usr/bin/python3}" tests/docker_smoke.py --image "$image"
echo "GPU build, runtime imports, native harnesses, and Docker smoke passed: $image"
