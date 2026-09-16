#!/bin/bash
# One-shot incumbent status. The script does not poll or sleep.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "INCUMBENT_STATUS=missing ready=no"; exit 1; }

launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
eval_pid=$(cat "$RUN_DIR/eval.pid" 2>/dev/null || true)
server=$(cat "$RUN_DIR/server.pid" 2>/dev/null || true)
launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
eval_alive=0; [ -n "$eval_pid" ] && kill -0 "$eval_pid" 2>/dev/null && eval_alive=1
server_alive=0; [ -n "$server" ] && kill -0 "$server" 2>/dev/null && server_alive=1

health=0
python - "$A_PORT" >/dev/null 2>&1 <<'PY' && health=1
import json
import sys
import urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY

gpu=$(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]//g' | paste -sd ';' -)
phase=missing; next_phase=missing; cycle=0; completed=0; success=0; errors=0; active=0
peak_count=0; current_vram=0; baseline_vram=0; peak_vram=0; peak_active=0
if [ -f "$RUN_DIR/progress.json" ]; then
  read -r phase next_phase cycle completed success errors active peak_count current_vram baseline_vram peak_vram peak_active < <(python - "$RUN_DIR/progress.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
print(
    d.get("phase", "missing"),
    d.get("next_phase", "missing"),
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
fi

ready=no
peak_delta=$((peak_vram - baseline_vram))
if [ "$launcher_alive" = 1 ] && [ "$eval_alive" = 1 ] && [ "$server_alive" = 1 ] && [ "$health" = 1 ] \
   && [ "$peak_active" = 1 ] && [ "$current_vram" -ge "$A_LONG_PEAK_VRAM_MB" ] \
   && [ "$peak_count" -ge 1 ] && [ "$peak_delta" -ge "$A_MIN_PEAK_DELTA_MB" ]; then
  ready=yes
fi

echo "INCUMBENT_STATUS phase=$phase next_phase=$next_phase cycle=$cycle launcher_alive=$launcher_alive eval_alive=$eval_alive server_alive=$server_alive health=$health completed=$completed success=$success errors=$errors active=$active peak_count=$peak_count current_vram_mb=$current_vram baseline_vram_mb=$baseline_vram peak_vram_mb=$peak_vram peak_window_active=$peak_active ready=$ready launcher_pid=${launcher:-none} eval_pid=${eval_pid:-none} server_pid=${server:-none} gpu_processes=${gpu:-none} run=$RUN_DIR"
tail -8 "$RUN_DIR/context_ramp.log" 2>/dev/null | sed 's/^/CONTEXT_RAMP /'
tail -8 "$RUN_DIR/vllm.log" 2>/dev/null | sed 's/^/VLLM /'
