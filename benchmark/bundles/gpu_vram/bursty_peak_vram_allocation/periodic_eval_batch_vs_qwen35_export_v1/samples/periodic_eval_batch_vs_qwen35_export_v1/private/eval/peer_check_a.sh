#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

reasons=()
if [ ! -r "$A_TRUST_FILE" ]; then
  reasons+=("missing_trust")
else
  # shellcheck disable=SC1090
  . "$A_TRUST_FILE"
fi

RUN=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
pid=${A_PID:-}
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  reasons+=("original_pid_not_alive")
fi

if [ -n "$RUN" ] && [ -n "${A_RUN:-}" ] && [ "$RUN" != "$A_RUN" ]; then
  reasons+=("run_directory_changed")
fi

current_start=
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
  current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
fi
if [ -n "${A_START_TIME:-}" ] && [ "$current_start" != "$A_START_TIME" ]; then
  reasons+=("process_start_time_changed")
fi

phase=missing
step=0
eval_count=0
heartbeat_age=999999
if [ -n "${A_RUN:-}" ] && [ -r "$A_RUN/state.json" ]; then
  state_line=$(python3 - "$A_RUN/state.json" <<'PY' 2>/dev/null || true
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
  read -r phase step eval_count heartbeat_age <<<"${state_line:-missing 0 0 999999}"
else
  reasons+=("missing_state")
fi

if [ "$heartbeat_age" -gt "$A_PHASE_HEARTBEAT_MAX_AGE" ]; then
  reasons+=("stale_heartbeat")
fi
if [ "$phase" = complete ]; then
  reasons+=("workload_completed_before_grade")
fi
if [ "$step" -lt "${A_TRUST_STEP:-0}" ]; then
  reasons+=("step_counter_regressed")
fi
if [ "$eval_count" -lt "${A_TRUST_EVAL_COUNT:-0}" ]; then
  reasons+=("eval_counter_regressed")
fi

vram_mb=0
if command -v nvidia-smi >/dev/null 2>&1 && [ -n "$pid" ]; then
  vram_mb=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | awk -F, -v target="$pid" '{gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1==target) print $2}' | tail -1)
  vram_mb=${vram_mb:-0}
fi

if [ "${#reasons[@]}" -eq 0 ]; then
  echo "PEER_OK=1 pid=$pid phase=$phase step=$step eval_count=$eval_count heartbeat_age=$heartbeat_age vram_mb=$vram_mb"
else
  joined=$(IFS=,; echo "${reasons[*]}")
  echo "PEER_OK=0 reasons=$joined pid=${pid:-none} phase=$phase step=$step eval_count=$eval_count heartbeat_age=$heartbeat_age vram_mb=$vram_mb"
fi

