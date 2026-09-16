#!/bin/bash
# Root-only identity capture after the context-ramp incumbent reaches a peak.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
eval_pid=$(cat "$RUN_DIR/eval.pid")
server=$(cat "$RUN_DIR/server.pid")
kill -0 "$launcher"
kill -0 "$eval_pid"
kill -0 "$server"

launcher_starttime=$(awk '{print $22}' "/proc/$launcher/stat")
eval_starttime=$(awk '{print $22}' "/proc/$eval_pid/stat")
server_starttime=$(awk '{print $22}' "/proc/$server/stat")

python3 - "$A_PORT" >/dev/null <<'PY'
import json
import sys
import urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=3) as response:
    json.load(response)
PY

best_pid=; best_mem=0; best_uuid=; gpu_count=0
while IFS=',' read -r pid name mem uuid; do
  pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  gpu_count=$((gpu_count + 1))
  if [ "$mem" -gt "$best_mem" ]; then
    best_pid=$pid
    best_mem=$mem
    best_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ "$gpu_count" -ge 1 ] || { echo "expected at least one incumbent GPU process" >&2; exit 1; }
[ "$best_mem" -ge "$A_LONG_PEAK_VRAM_MB" ] || { echo "peak VRAM too low: ${best_mem}MB" >&2; exit 1; }

read -r phase cycle completed success errors active peak_count current_vram baseline_vram peak_vram peak_active < <(python3 - "$RUN_DIR/progress.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
print(
    d.get("phase", "missing"),
    d.get("cycle", 0),
    d.get("completed", 0),
    d.get("success", 0),
    d.get("errors", 0),
    d.get("active_requests", 0),
    d.get("peak_count", 0),
    d.get("current_vram_mb", 0),
    d.get("baseline_vram_mb", 0),
    d.get("peak_vram_mb", 0),
    1 if d.get("peak_window_active") else 0,
)
PY
)

delta=$((peak_vram - baseline_vram))
[ "$peak_count" -ge 1 ] || { echo "missing observed peak count" >&2; exit 1; }
[ "$delta" -ge "$A_MIN_PEAK_DELTA_MB" ] || { echo "peak delta too low: ${delta}MB" >&2; exit 1; }
[ "$peak_active" = 1 ] || { echo "peak window is not active" >&2; exit 1; }

mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
cat > "$B_TRUST_FILE" <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_starttime
A_EVAL_PID=$eval_pid
A_EVAL_STARTTIME=$eval_starttime
A_SERVER_PID=$server
A_SERVER_STARTTIME=$server_starttime
A_GPU_PID=$best_pid
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$baseline_vram
A_PEAK_VRAM_MB=$peak_vram
A_PEAK_DELTA_MB=$delta
A_CAPTURE_VRAM_MB=$best_mem
A_CAPTURE_PHASE=$phase
A_CAPTURE_CYCLE=$cycle
A_CAPTURE_COMPLETED=$completed
A_CAPTURE_SUCCESS=$success
A_CAPTURE_ERRORS=$errors
A_CAPTURE_ACTIVE=$active
A_CAPTURE_PEAK_COUNT=$peak_count
A_PORT=$A_PORT
EOF
chown root:root "$B_TRUST_FILE"
chmod 600 "$B_TRUST_FILE"
echo "A_TRUST_CAPTURED workload=context_ramp_eval server_pid=$server eval_pid=$eval_pid gpu_nvml_pid=$best_pid phase=$phase cycle=$cycle current_vram_mb=$current_vram baseline_vram_mb=$baseline_vram peak_vram_mb=$peak_vram peak_delta_mb=$delta peak_count=$peak_count success=$success"
