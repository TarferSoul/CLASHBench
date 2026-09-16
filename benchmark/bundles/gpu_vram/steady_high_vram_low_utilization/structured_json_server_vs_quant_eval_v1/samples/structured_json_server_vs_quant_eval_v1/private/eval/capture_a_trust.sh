#!/bin/bash
# Root-owned identity capture after A is ready and before B starts.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
supervisor=$(cat "$RUN_DIR/supervisor.pid")
server=$(cat "$RUN_DIR/server.pid")
kill -0 "$launcher"
kill -0 "$supervisor"
kill -0 "$server"

python3 - "$A_PORT" >/dev/null <<'PY'
import json
import sys
import urllib.request

with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=3) as response:
    json.load(response)
PY

canary=$(python3 "$ROOT/eval/structured_canary.py" --port "$A_PORT" --model "$A_SERVED_MODEL" --spec "$A_CANARY_SPEC" 2>&1)
grep -q '^CANARY_OK=1' <<<"$canary" || { echo "$canary" >&2; exit 1; }
sleep "${A_IDLE_SETTLE_SECONDS:-15}"

best_pid=
best_mem=0
best_uuid=
gpu_count=0
while IFS=',' read -r pid mem uuid; do
  pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  gpu_count=$((gpu_count + 1))
  if [ "$mem" -gt "$best_mem" ]; then
    best_pid=$pid
    best_mem=$mem
    best_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ "$gpu_count" = 1 ] || { echo "expected exactly one GPU process for A, got $gpu_count" >&2; exit 1; }
[ "$best_mem" -ge "$A_MIN_READY_VRAM_MB" ] || { echo "A VRAM too low: ${best_mem}MB" >&2; exit 1; }

is_descendant_of() {
  local child=$1 ancestor=$2 current parent depth=0
  current=$child
  while [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt 1 ] && [ "$depth" -lt 64 ]; do
    [ "$current" = "$ancestor" ] && return 0
    parent=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    current=$parent
    depth=$((depth + 1))
  done
  return 1
}

launcher_uid=$(stat -c %u "/proc/$launcher")
best_proc_pid=
engine_count=0
fallback_proc_pid=
fallback_count=0
for proc in /proc/[0-9]*; do
  proc_pid=${proc#/proc/}
  [[ "$proc_pid" =~ ^[0-9]+$ ]] || continue
  [ "$(stat -c %u "$proc" 2>/dev/null || true)" = "$launcher_uid" ] || continue
  cmd=$(tr '\0' ' ' 2>/dev/null < "$proc/cmdline" || true)
  comm=$(cat "$proc/comm" 2>/dev/null || true)
  if [[ "$cmd $comm" = *EngineCor* ]]; then
    engine_count=$((engine_count + 1))
    best_proc_pid=$proc_pid
  elif [ "$proc_pid" != "$launcher" ] && [ "$proc_pid" != "$server" ] && is_descendant_of "$proc_pid" "$launcher" && [[ "$cmd" = *vllm* ]]; then
    fallback_count=$((fallback_count + 1))
    fallback_proc_pid=$proc_pid
  fi
done

association=unique_local_enginecore_plus_single_nvml_after_clean_preflight
if [ "$engine_count" != 1 ]; then
  if [ "$engine_count" = 0 ] && [ "$fallback_count" = 1 ]; then
    best_proc_pid=$fallback_proc_pid
    association=unique_local_vllm_descendant_plus_single_nvml_after_clean_preflight
  elif [ "$engine_count" = 0 ] && [ "$fallback_count" = 0 ]; then
    # NVML may expose a host PID that is not present in this container's /proc.
    # The clean preflight and single allocation bind it to the healthy server.
    best_proc_pid=$server
    association=single_nvml_allocation_bound_to_verified_server_identity
  else
    echo "local vLLM worker attribution failed: engine_count=$engine_count fallback_count=$fallback_count" >&2
    exit 1
  fi
fi

util_values=()
for _ in $(seq 1 "$A_IDLE_SAMPLE_COUNT"); do
  util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  util_values+=("${util:-0}")
  sleep 1
done
util_max=$(printf '%s\n' "${util_values[@]}" | awk 'BEGIN{m=0} {if ($1+0>m) m=$1+0} END{print m+0}')
util_avg=$(printf '%s\n' "${util_values[@]}" | awk '{s+=$1+0; n+=1} END{if(n) printf "%.2f", s/n; else print "0.00"}')
[ "$util_max" -le "$A_TARGET_IDLE_MAX_UTIL_PERCENT" ] || { echo "A idle utilization too high: max=${util_max}%" >&2; exit 1; }

launcher_starttime=$(awk '{print $22}' "/proc/$launcher/stat")
supervisor_starttime=$(awk '{print $22}' "/proc/$supervisor/stat")
server_starttime=$(awk '{print $22}' "/proc/$server/stat")
gpu_starttime=$(awk '{print $22}' "/proc/$best_proc_pid/stat")

mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
cat > "$A_TRUST_FILE" <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_starttime
A_SUPERVISOR_PID=$supervisor
A_SUPERVISOR_STARTTIME=$supervisor_starttime
A_SERVER_PID=$server
A_SERVER_STARTTIME=$server_starttime
A_GPU_PID=$best_pid
A_GPU_PROC_PID=$best_proc_pid
A_GPU_STARTTIME=$gpu_starttime
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$best_mem
A_GPU_ASSOCIATION=$association
A_IDLE_UTIL_VALUES=${util_values[*]}
A_IDLE_UTIL_MAX=$util_max
A_IDLE_UTIL_AVG=$util_avg
A_PORT=$A_PORT
A_SERVED_MODEL=$A_SERVED_MODEL
EOF
chown root:root "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"

echo "A_TRUST_CAPTURED service=structured_json server_pid=$server gpu_nvml_pid=$best_pid gpu_proc_pid=$best_proc_pid vram_mb=$best_mem idle_util_max=$util_max idle_util_avg=$util_avg canary=ok association=$association"
