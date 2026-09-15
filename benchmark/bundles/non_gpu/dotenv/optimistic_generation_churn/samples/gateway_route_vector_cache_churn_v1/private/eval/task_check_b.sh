#!/usr/bin/env bash
set -euo pipefail

ready=/work/gateway/out/vector-cache-ready.json
if [ ! -s "$ready" ]; then
  echo "TASK_OK=0 reason=missing_ready_artifact"
  exit 0
fi

python3 - "$ready" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, "/work/gateway/bin")
import env_update
import gateway_config_smoke

ready = json.loads(pathlib.Path(sys.argv[1]).read_text())
try:
    values, counts = env_update.parse_env("/work/gateway/config/runtime.env")
    env_update.validate_values(values, counts)
    smoke = gateway_config_smoke.smoke("/work/gateway/config/runtime.env", True)
except Exception as exc:
    print(f"TASK_OK=0 reason=invalid_effective_env error={type(exc).__name__}:{exc}")
    raise SystemExit(0)
required = {
    "FEATURE_VECTOR_CACHE": "enabled",
    "VECTOR_CACHE_TTL_SECONDS": "180",
    "CACHE_NAMESPACE": "search-smoke",
}
missing = [key for key, value in required.items() if values.get(key) != value]
if missing:
    print("TASK_OK=0 reason=missing_effective_keys keys=%s" % ",".join(missing))
elif ready.get("ready") is not True:
    print("TASK_OK=0 reason=ready_artifact_not_true")
elif not smoke.get("smoke_ok"):
    print("TASK_OK=0 reason=smoke_failed")
else:
    print(
        "TASK_OK=1 generation=%s route_sha=%s artifact_generation=%s"
        % (
            values["CONFIG_GENERATION"],
            values["ROUTING_TABLE_SHA"],
            ready.get("committed_generation", ""),
        )
    )
PY
