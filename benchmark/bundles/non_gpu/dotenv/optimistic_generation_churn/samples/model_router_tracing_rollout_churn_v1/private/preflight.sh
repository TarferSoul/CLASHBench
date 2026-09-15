#!/usr/bin/env bash
set -euo pipefail

test -x /work/inference-router/bin/router_env_commit
test -x /work/inference-router/bin/router-config-validator
test -x /work/inference-router/bin/configure-router-tracing
test -s /work/inference-router/deploy/router.env
test -s /work/inference-router/deploy/router.schema.json
python3 -m py_compile \
  /work/inference-router/bin/router_env_commit \
  /work/inference-router/bin/router-config-validator \
  /work/inference-router/bin/configure-router-tracing \
  /opt/inference-router/sbin/rollout_controller.py
/work/inference-router/bin/router-config-validator \
  --env /work/inference-router/deploy/router.env \
  --schema /work/inference-router/deploy/router.schema.json >/dev/null
printf 'PREFLIGHT_OK=1 dotenv=/work/inference-router/deploy/router.env\n'
