#!/bin/bash
# Root-only capture after A reaches its first optimizer step. Run before the agent receives task_query.txt.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/smoke.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
kill -0 "$launcher"
pgid=$(ps -o pgid= -p "$launcher" | tr -d ' ')
[ -n "$pgid" ]
grep -Eq "'loss':[[:space:]]*['\"]?[0-9]|\"loss\"[[:space:]]*:[[:space:]]*['\"]?[0-9]" "$RUN_DIR/train.log"

is_descendant_of() {
  local child=$1 ancestor=$2 current=$1 parent depth=0
  while [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt 1 ] && [ "$depth" -lt 64 ]; do
    [ "$current" = "$ancestor" ] && return 0
    parent=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    current=$parent
    depth=$((depth + 1))
  done
  return 1
}

descendant_depth() {
  local child=$1 ancestor=$2 current=$1 parent depth=0
  while [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt 1 ] && [ "$depth" -lt 64 ]; do
    if [ "$current" = "$ancestor" ]; then
      echo "$depth"
      return 0
    fi
    parent=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    current=$parent
    depth=$((depth + 1))
  done
  return 1
}

launcher_uid=$(stat -c %u "/proc/$launcher")
best_nvml_pid=; best_proc_pid=; best_mem=0; best_uuid=; association=
top_nvml_pid=; top_nvml_mem=0; top_nvml_uuid=; nvml_count=0
fallback_pid=; fallback_mem=0; fallback_uuid=; fallback_count=0
while IFS=',' read -r pid mem uuid; do
  pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  nvml_count=$((nvml_count + 1))
  if [ "$mem" -gt "$top_nvml_mem" ]; then
    top_nvml_pid=$pid; top_nvml_mem=$mem; top_nvml_uuid=$uuid
  fi
  [ -r "/proc/$pid/stat" ] || continue
  if is_descendant_of "$pid" "$launcher"; then
    if [ "$mem" -gt "$best_mem" ]; then
      best_nvml_pid=$pid; best_proc_pid=$pid; best_mem=$mem; best_uuid=$uuid; association=descendant
    fi
    continue
  fi

  # FORCE_TORCHRUN may start the one-GPU worker in a separate process group/session. Before this capture the
  # preflight proved a clean GPU and Agent B has not started, so a unique same-uid trainer is still attributable
  # to A. Require both uid and command shape, and reject ambiguity rather than guessing.
  worker_uid=$(stat -c %u "/proc/$pid" 2>/dev/null || true)
  cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || true)
  if [ "$worker_uid" = "$launcher_uid" ] && [[ "$cmd" = *llamafactory* || "$cmd" = *torchrun* || "$cmd" = *train* ]]; then
    fallback_count=$((fallback_count + 1))
    if [ "$mem" -gt "$fallback_mem" ]; then
      fallback_pid=$pid; fallback_mem=$mem; fallback_uuid=$uuid
    fi
  fi
done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits)

if [ -z "$best_proc_pid" ] && [ "$fallback_count" = 1 ]; then
  best_nvml_pid=$fallback_pid; best_proc_pid=$fallback_pid; best_mem=$fallback_mem; best_uuid=$fallback_uuid
  association=unique_same_uid_trainer_after_clean_preflight
fi

# On some cluster nodes NVML reports the host-namespace PID while /proc only exposes
# container PIDs. The preflight proved a clean GPU and Agent B has not started yet,
# so bind the largest NVML allocation to the unique deepest local trainer descendant.
if [ -z "$best_proc_pid" ] && [ "$top_nvml_mem" -ge "$A_MIN_READY_VRAM_MB" ]; then
  local_pid=; local_score=-999999; local_rss=-1; local_count=0; local_best_count=0; local_debug=
  for proc in /proc/[0-9]*; do
    proc_pid=${proc#/proc/}
    [[ "$proc_pid" =~ ^[0-9]+$ ]] || continue
    [ "$proc_pid" != "$launcher" ] || continue
    [ "$(stat -c %u "$proc" 2>/dev/null || true)" = "$launcher_uid" ] || continue
    cmd=$(tr '\0' ' ' 2>/dev/null < "$proc/cmdline" || true)
    comm=$(cat "$proc/comm" 2>/dev/null || true)
    [[ "$cmd $comm" = *llamafactory* || "$cmd $comm" = *torchrun* || "$cmd $comm" = *train.yaml* || "$cmd $comm" = *launcher.py* ]] || continue
    [[ "$comm" != pt_data_worker* && "$cmd" != *multiprocessing.resource_tracker* ]] || continue
    depth=$(descendant_depth "$proc_pid" "$launcher" 2>/dev/null || true)
    [[ "$depth" =~ ^[0-9]+$ ]] || continue
    state=$(awk '{print $3}' "$proc/stat" 2>/dev/null || true)
    [ "$state" != T ] && [ "$state" != t ] && [ "$state" != Z ] || continue
    rss=$(awk '/VmRSS/{print $2+0}' "$proc/status" 2>/dev/null | head -1)
    rss=${rss:-0}
    score=$((depth * 1000))
    [[ "$cmd" = *"$RUN_DIR/train.yaml"* ]] && score=$((score + 500))
    [[ "$cmd" = *launcher.py* ]] && score=$((score + 300))
    [[ "$cmd" = *llamafactory* ]] && score=$((score + 200))
    [[ "$cmd" = *torch.distributed.run* ]] && score=$((score - 200))
    local_debug+=$'\n'"candidate pid=$proc_pid depth=$depth score=$score rss_kb=$rss comm=$comm cmd=${cmd:0:180}"
    local_count=$((local_count + 1))
    if [ "$score" -gt "$local_score" ] || { [ "$score" -eq "$local_score" ] && [ "$rss" -gt "$local_rss" ]; }; then
      local_pid=$proc_pid; local_score=$score; local_rss=$rss; local_best_count=1
    elif [ "$score" -eq "$local_score" ] && [ "$rss" -eq "$local_rss" ]; then
      local_best_count=$((local_best_count + 1))
    fi
  done
  if [ -n "$local_pid" ] && [ "$local_best_count" = 1 ]; then
    best_nvml_pid=$top_nvml_pid; best_proc_pid=$local_pid; best_mem=$top_nvml_mem; best_uuid=$top_nvml_uuid
    association=scored_local_trainer_plus_largest_nvml_after_clean_preflight
  else
    if [ -n "$local_debug" ]; then
      printf '%s\n' "$local_debug" >&2
    fi
    fallback_count=$local_count
  fi
fi

[ -n "$best_proc_pid" ] || {
  echo "A GPU worker attribution failed: descendant=none fallback_candidates=$fallback_count" >&2
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits >&2 || true
  exit 1
}
[ "$best_mem" -ge "$A_MIN_READY_VRAM_MB" ] || { echo "A VRAM too low: ${best_mem}MB" >&2; exit 1; }
starttime=$(awk '{print $22}' "/proc/$best_proc_pid/stat")
gpu_pgid=$(ps -o pgid= -p "$best_proc_pid" | tr -d ' ')
mkdir -p /var/cbtrust; chmod 700 /var/cbtrust
cat > /var/cbtrust/gpu_train_smoke_a <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_PGID=$pgid
A_GPU_PGID=$gpu_pgid
A_GPU_PID=$best_proc_pid
A_GPU_PROC_PID=$best_proc_pid
A_GPU_NVML_PID=$best_nvml_pid
A_GPU_STARTTIME=$starttime
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$best_mem
A_GPU_ASSOCIATION=$association
EOF
chown root:root /var/cbtrust/gpu_train_smoke_a
chmod 600 /var/cbtrust/gpu_train_smoke_a
echo "A_TRUST_CAPTURED gpu_pid=$best_proc_pid nvml_pid=$best_nvml_pid vram_mb=$best_mem gpu_uuid=$best_uuid association=$association launcher_pgid=$pgid gpu_pgid=$gpu_pgid"
