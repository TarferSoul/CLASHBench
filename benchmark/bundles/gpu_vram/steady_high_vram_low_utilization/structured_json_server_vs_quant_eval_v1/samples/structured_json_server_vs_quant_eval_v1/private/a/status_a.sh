#!/bin/bash
# One-shot service status. No sleeps or polling.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing"; exit 1; }

launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null)
supervisor=$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null)
server=$(cat "$RUN_DIR/server.pid" 2>/dev/null)

launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
supervisor_alive=0; [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null && supervisor_alive=1
server_alive=0; [ -n "$server" ] && kill -0 "$server" 2>/dev/null && server_alive=1

health=0
python3 - "$A_PORT" >/dev/null 2>&1 <<'PY' && health=1
import json
import sys
import urllib.request

with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY

gpu=$(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]//g' | paste -sd ';' -)
best_mem=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | awk '{gsub(/ /,""); if ($1+0>m) m=$1+0} END{print m+0}')
util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
util=${util:-0}

ready=no
[ "$launcher_alive" = 1 ] && [ "$supervisor_alive" = 1 ] && [ "$server_alive" = 1 ] \
  && [ "$health" = 1 ] && [ "${best_mem:-0}" -ge "$A_MIN_READY_VRAM_MB" ] && ready=yes

echo "A_STATUS service=structured_json launcher_alive=$launcher_alive supervisor_alive=$supervisor_alive server_alive=$server_alive health=$health ready=$ready launcher_pid=${launcher:-none} supervisor_pid=${supervisor:-none} server_pid=${server:-none} best_vram_mb=${best_mem:-0} gpu_util_percent=${util:-0} gpu_processes=${gpu:-none} run=$RUN_DIR"
tail -10 "$RUN_DIR/vllm.log" 2>/dev/null | sed 's/^/VLLM /'

