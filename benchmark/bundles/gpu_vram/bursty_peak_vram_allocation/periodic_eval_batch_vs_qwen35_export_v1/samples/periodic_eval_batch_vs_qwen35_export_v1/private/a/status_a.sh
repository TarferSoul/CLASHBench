#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

RUN=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
pid=
[ -n "$RUN" ] && pid=$(cat "$RUN/worker.pid" 2>/dev/null || true)

alive=no
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  alive=yes
fi

phase=missing
step=0
eval_count=0
heartbeat_age=999999
last_loss=null
last_eval_loss=null
if [ -n "$RUN" ] && [ -r "$RUN/state.json" ]; then
  state_out=$(python3 - "$RUN/state.json" <<'PY' 2>/dev/null || true
import json, sys, time
with open(sys.argv[1]) as fh:
    data = json.load(fh)
age = int(time.time() - float(data.get("heartbeat", 0)))
print("phase={phase} step={step} eval_count={eval_count} heartbeat_age={age} last_loss={loss} last_eval_loss={eval_loss}".format(
    phase=data.get("phase", "unknown"),
    step=int(data.get("train_steps") or 0),
    eval_count=int(data.get("eval_batches") or 0),
    age=age,
    loss=data.get("last_loss"),
    eval_loss=data.get("last_eval_loss"),
))
PY
)
  for item in $state_out; do
    case "$item" in
      phase=*) phase=${item#phase=} ;;
      step=*) step=${item#step=} ;;
      eval_count=*) eval_count=${item#eval_count=} ;;
      heartbeat_age=*) heartbeat_age=${item#heartbeat_age=} ;;
      last_loss=*) last_loss=${item#last_loss=} ;;
      last_eval_loss=*) last_eval_loss=${item#last_eval_loss=} ;;
    esac
  done
fi

vram_mb=0
if command -v nvidia-smi >/dev/null 2>&1 && [ -n "$pid" ]; then
  vram_mb=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | awk -F, -v target="$pid" '{gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1==target) print $2}' | tail -1)
  vram_mb=${vram_mb:-0}
fi

ready=no
if [ "$alive" = yes ] && [ "$step" -ge "$A_READY_MIN_TRAIN_STEPS" ] && [ "$heartbeat_age" -le "$A_PHASE_HEARTBEAT_MAX_AGE" ] && [ "$phase" != complete ]; then
  ready=yes
fi

echo "A_STATUS ready=$ready alive=$alive phase=$phase step=$step eval_count=$eval_count heartbeat_age=$heartbeat_age vram_mb=$vram_mb pid=${pid:-none} run=${RUN:-none} last_loss=$last_loss last_eval_loss=$last_eval_loss"

