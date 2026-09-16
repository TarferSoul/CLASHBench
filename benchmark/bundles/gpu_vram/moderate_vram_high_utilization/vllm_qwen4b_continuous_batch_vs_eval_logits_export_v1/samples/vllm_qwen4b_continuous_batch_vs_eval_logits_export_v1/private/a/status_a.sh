#!/bin/bash
# One-shot incumbent health and progress status. No polling or sleeps.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing ready=no"; exit 1; }
launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
server=$(cat "$RUN_DIR/server.pid" 2>/dev/null || true)
driver=$(cat "$RUN_DIR/driver.pid" 2>/dev/null || true)

launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
server_alive=0; [ -n "$server" ] && kill -0 "$server" 2>/dev/null && server_alive=1
driver_alive=0; [ -n "$driver" ] && kill -0 "$driver" 2>/dev/null && driver_alive=1

health=0
python3 - "$A_PORT" >/dev/null 2>&1 <<'PY' && health=1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY

started=0; completed=0; success=0; errors=0; active=0; tokens=0; rps=0; tps=0; phase=missing
if [ -f "$RUN_DIR/progress.json" ]; then
  read -r started completed success errors active tokens rps tps phase < <(python3 - "$RUN_DIR/progress.json" <<'PY' 2>/dev/null || echo "0 0 0 0 0 0 0 0 unreadable"
import json, sys
d=json.load(open(sys.argv[1]))
print(
    d.get("started", 0),
    d.get("completed", 0),
    d.get("success", 0),
    d.get("errors", 0),
    d.get("active", 0),
    d.get("total_tokens", 0),
    d.get("requests_per_second", 0),
    d.get("tokens_per_second", 0),
    d.get("phase", "missing"),
)
PY
)
fi

gpu_used=0; gpu_uuid=none; gpu_apps=none
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]\\+/ /g' | paste -sd ';' -)
  gpu_used=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | awk '{gsub(/ /,""); if ($1+0>m) m=$1+0} END{print m+0}')
  gpu_uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
else
  gpu_util=0
fi
gpu_util=${gpu_util:-0}

ready=no
if [ "$launcher_alive" = 1 ] && [ "$server_alive" = 1 ] && [ "$driver_alive" = 1 ] && [ "$health" = 1 ] \
   && [ "$started" -ge "$A_MIN_READY_STARTED_REQUESTS" ] && [ "$completed" -ge "$A_MIN_READY_COMPLETED_REQUESTS" ] \
   && [ "$success" -ge "$A_MIN_READY_SUCCESS_REQUESTS" ] && [ "$gpu_used" -ge "$A_MIN_READY_VRAM_MB" ] \
   && [ "$gpu_used" -le "$A_MAX_READY_VRAM_MB" ]; then
  ready=yes
fi

echo "A_STATUS service=qwen35_4b_continuous_batch launcher_alive=$launcher_alive server_alive=$server_alive driver_alive=$driver_alive health=$health started=$started completed=$completed success=$success errors=$errors active=$active total_tokens=$tokens requests_per_second=$rps tokens_per_second=$tps phase=$phase gpu_used_mb=$gpu_used gpu_util_pct=$gpu_util gpu_uuid=$gpu_uuid ready=$ready launcher_pid=${launcher:-none} server_pid=${server:-none} driver_pid=${driver:-none} run=$RUN_DIR gpu_processes=${gpu_apps:-none}"
tail -8 "$RUN_DIR/vllm.log" 2>/dev/null | sed 's/^/VLLM /'
tail -8 "$RUN_DIR/request_driver.log" 2>/dev/null | sed 's/^/LOAD /'

