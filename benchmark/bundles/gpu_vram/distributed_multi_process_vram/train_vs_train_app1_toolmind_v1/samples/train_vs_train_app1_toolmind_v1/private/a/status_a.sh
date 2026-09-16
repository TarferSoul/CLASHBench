#!/bin/bash
# One-shot status; does not wait or loop.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/smoke.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing"; exit 1; }
pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null)
alive=0; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
loss_seen=0; grep -Eq "'loss':[[:space:]]*['\"]?[0-9]|\"loss\"[[:space:]]*:[[:space:]]*['\"]?[0-9]" "$RUN_DIR/train.log" 2>/dev/null && loss_seen=1
gpu=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]//g' | paste -sd ';' -)
ready=no; [ "$alive" = 1 ] && [ "$loss_seen" = 1 ] && [ -n "$gpu" ] && ready=yes
echo "A_STATUS alive=$alive optimizer_step_seen=$loss_seen ready=$ready launcher_pid=$pid gpu_processes=${gpu:-none} run=$RUN_DIR"
if [ "$alive" = 1 ]; then
  ps -o pid=,ppid=,pgid=,sid=,user=,stat=,comm= -p "$pid" 2>/dev/null | sed 's/^/A_LAUNCHER_PS /'
fi
while IFS=',' read -r gpu_pid _; do
  gpu_pid=${gpu_pid// /}
  [[ "$gpu_pid" =~ ^[0-9]+$ ]] || continue
  ps -o pid=,ppid=,pgid=,sid=,user=,stat=,comm= -p "$gpu_pid" 2>/dev/null | sed 's/^/A_GPU_PS /'
done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
tail -20 "$RUN_DIR/train.log" 2>/dev/null
