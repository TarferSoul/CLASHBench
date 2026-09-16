#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"

RUN=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
pid=
[ -n "$RUN" ] && pid=$(cat "$RUN/worker.pid" 2>/dev/null || true)
if [ -z "$RUN" ] || [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_TRUST_CAPTURED=0 reason=a_not_alive"
  exit 1
fi

start_time=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
gpu_uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)
vram_mb=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | awk -F, -v target="$pid" '{gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1==target) print $2}' | tail -1)
vram_mb=${vram_mb:-0}

state_line=$(python3 - "$RUN/state.json" <<'PY' 2>/dev/null || true
import json, sys, time
with open(sys.argv[1]) as fh:
    data = json.load(fh)
age = int(time.time() - float(data.get("heartbeat", 0)))
print("{phase} {step} {eval_count} {age}".format(
    phase=data.get("phase", "unknown"),
    step=int(data.get("train_steps") or 0),
    eval_count=int(data.get("eval_batches") or 0),
    age=age,
))
PY
)
read -r phase step eval_count heartbeat_age <<<"${state_line:-unknown 0 0 999999}"

tmp="$A_TRUST_FILE.tmp"
{
  printf 'A_PID=%q\n' "$pid"
  printf 'A_START_TIME=%q\n' "$start_time"
  printf 'A_PGID=%q\n' "$pgid"
  printf 'A_RUN=%q\n' "$RUN"
  printf 'A_GPU_UUID=%q\n' "$gpu_uuid"
  printf 'A_TRUST_VRAM_MB=%q\n' "$vram_mb"
  printf 'A_TRUST_PHASE=%q\n' "$phase"
  printf 'A_TRUST_STEP=%q\n' "$step"
  printf 'A_TRUST_EVAL_COUNT=%q\n' "$eval_count"
  printf 'A_TRUST_HEARTBEAT_AGE=%q\n' "$heartbeat_age"
  printf 'A_CAPTURED_AT=%q\n' "$(date -u +%FT%TZ)"
} > "$tmp"
mv "$tmp" "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"

echo "A_TRUST_CAPTURED=1 pid=$pid start_time=$start_time run=$RUN phase=$phase step=$step eval_count=$eval_count vram_mb=$vram_mb gpu_uuid=$gpu_uuid"

