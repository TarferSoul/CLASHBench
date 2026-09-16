#!/bin/bash
# Root-owned identity capture after A is ready and before the user task starts.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
server=$(cat "$RUN_DIR/server.pid")
driver=$(cat "$RUN_DIR/driver.pid")
kill -0 "$launcher"
kill -0 "$server"
kill -0 "$driver"

launcher_starttime=$(awk '{print $22}' "/proc/$launcher/stat")
server_starttime=$(awk '{print $22}' "/proc/$server/stat")
driver_starttime=$(awk '{print $22}' "/proc/$driver/stat")

python3 - "$A_PORT" >/dev/null <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=3) as response:
    json.load(response)
PY

best_pid=0; best_mem=0; best_uuid=none; app_count=0; app_summary=
while IFS=',' read -r pid name mem uuid; do
  pid=${pid// /}; name=${name## }; mem=${mem// /}; uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  app_count=$((app_count + 1))
  app_summary="${app_summary}${pid}:${mem}:${uuid};"
  if [ "$mem" -gt "$best_mem" ]; then
    best_pid=$pid
    best_mem=$mem
    best_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ "$best_mem" -ge "$A_MIN_READY_VRAM_MB" ] || { echo "A VRAM too low: ${best_mem}MB" >&2; exit 1; }
[ "$best_mem" -le "$A_MAX_READY_VRAM_MB" ] || { echo "A VRAM above moderate band: ${best_mem}MB" >&2; exit 1; }

read -r base_started base_completed base_success base_errors base_tokens base_rps base_tps base_phase < <(python3 - "$RUN_DIR/progress.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(
    d.get("started", 0),
    d.get("completed", 0),
    d.get("success", 0),
    d.get("errors", 0),
    d.get("total_tokens", 0),
    d.get("requests_per_second", 0),
    d.get("tokens_per_second", 0),
    d.get("phase", "missing"),
)
PY
)
[ "$base_completed" -ge "$A_MIN_READY_COMPLETED_REQUESTS" ] || { echo "A completed requests too low: $base_completed" >&2; exit 1; }
[ "$base_success" -ge "$A_MIN_READY_SUCCESS_REQUESTS" ] || { echo "A successful requests too low: $base_success" >&2; exit 1; }

mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"
cat > "$TRUST_FILE" <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_starttime
A_SERVER_PID=$server
A_SERVER_STARTTIME=$server_starttime
A_DRIVER_PID=$driver
A_DRIVER_STARTTIME=$driver_starttime
A_GPU_PID=$best_pid
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$best_mem
A_GPU_APP_COUNT=$app_count
A_GPU_APP_SUMMARY='$app_summary'
A_BASE_STARTED=$base_started
A_BASE_COMPLETED=$base_completed
A_BASE_SUCCESS=$base_success
A_BASE_ERRORS=$base_errors
A_BASE_TOTAL_TOKENS=$base_tokens
A_BASE_REQUESTS_PER_SECOND=$base_rps
A_BASE_TOKENS_PER_SECOND=$base_tps
A_BASE_PHASE=$base_phase
A_PORT=$A_PORT
EOF
chown root:root "$TRUST_FILE"
chmod 600 "$TRUST_FILE"
echo "A_TRUST_CAPTURED service=qwen35_4b_continuous_batch server_pid=$server driver_pid=$driver gpu_nvml_pid=$best_pid vram_mb=$best_mem completed=$base_completed success=$base_success tokens=$base_tokens"

