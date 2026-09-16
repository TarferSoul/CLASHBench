#!/bin/bash
# One-shot status. No polling or sleeps.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing"; exit 1; }
launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null)
server=$(cat "$RUN_DIR/server.pid" 2>/dev/null)
eval_pid=$(cat "$RUN_DIR/eval.pid" 2>/dev/null)
launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
server_alive=0; [ -n "$server" ] && kill -0 "$server" 2>/dev/null && server_alive=1
eval_alive=0; [ -n "$eval_pid" ] && kill -0 "$eval_pid" 2>/dev/null && eval_alive=1
health=0
python - "$A_PORT" >/dev/null 2>&1 <<'PY' && health=1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY
gpu=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]//g' | paste -sd ';' -)
started=0; active=0; completed=0; success=0; phase=missing
if [ -f "$RUN_DIR/atbench_progress.json" ]; then
  read -r started active completed success phase < <(python - "$RUN_DIR/atbench_progress.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get('started',0), d.get('active',0), d.get('completed',0), d.get('success',0), d.get('phase','missing'))
PY
)
fi
ready=no
if [ "$A_MODE" = idle ]; then
  [ "$launcher_alive" = 1 ] && [ "$server_alive" = 1 ] && [ "$health" = 1 ] && [ -n "$gpu" ] && ready=yes
else
  [ "$launcher_alive" = 1 ] && [ "$server_alive" = 1 ] && [ "$eval_alive" = 1 ] && [ "$health" = 1 ] \
    && [ "$started" -ge 50 ] && [ "$active" -gt 0 ] && [ "$success" -ge 1 ] && ready=yes
fi
echo "A_STATUS mode=$A_MODE launcher_alive=$launcher_alive server_alive=$server_alive health=$health eval_alive=$eval_alive started=$started active=$active completed=$completed success=$success phase=$phase ready=$ready launcher_pid=${launcher:-none} server_pid=${server:-none} eval_pid=${eval_pid:-none} gpu_processes=${gpu:-none} run=$RUN_DIR"
tail -8 "$RUN_DIR/vllm.log" 2>/dev/null | sed 's/^/VLLM /'
tail -8 "$RUN_DIR/atbench_eval.log" 2>/dev/null | sed 's/^/ATBENCH /'
