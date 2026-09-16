#!/bin/bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_STATUS alive=0 ready=no reason=no_current_run"; exit 1; }
pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
alive=0
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1

loss_count=$(awk '/\047loss\047:[[:space:]]*[\047\"]?[0-9]|"loss"[[:space:]]*:[[:space:]]*[\047\"]?[0-9]/ { count++ } END { print count + 0 }' "$RUN_DIR/train.log" 2>/dev/null || echo 0)
checkpoint_count=$(find "$RUN_DIR/$A_TRAIN_OUTPUT_SUBDIR" -maxdepth 3 -type f \( -name 'trainer_state.json' -o -name 'optimizer.pt' -o -name '*.safetensors' \) 2>/dev/null | wc -l | tr -d ' ')
gpu_csv=$(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]//g' | paste -sd ';' -)
top_mem=0
top_pid=
while IFS=',' read -r gpu_pid mem _uuid; do
  gpu_pid=${gpu_pid// /}
  mem=${mem// /}
  [[ "$gpu_pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  if [ "$mem" -gt "$top_mem" ]; then
    top_mem=$mem
    top_pid=$gpu_pid
  fi
done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null)

util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1{gsub(/ /,""); print $1+0}')
util=${util:-0}
ready=no
reason=waiting
if [ "$alive" = 0 ]; then
  reason=launcher_not_alive
elif [ "$loss_count" -lt "${A_MIN_LOSS_RECORDS:-1}" ]; then
  reason=loss_steps_below_floor
elif [ "$top_mem" -lt "${A_MIN_READY_VRAM_MB:-1}" ]; then
  reason=vram_below_floor
elif [ "$util" -lt "${A_MIN_GPU_UTILIZATION_PCT:-0}" ]; then
  reason=utilization_below_floor
else
  ready=yes
  reason=healthy
fi

echo "A_STATUS alive=$alive ready=$ready reason=$reason launcher_pid=${pid:-none} gpu_pid=${top_pid:-none} top_vram_mb=$top_mem gpu_util_pct=$util loss_records=$loss_count checkpoint_files=$checkpoint_count run=$RUN_DIR gpu_processes=${gpu_csv:-none}"
if [ "$alive" = 1 ]; then
  ps -o pid=,ppid=,pgid=,sid=,user=,stat=,comm= -p "$pid" 2>/dev/null | sed 's/^/A_LAUNCHER_PS /'
fi
tail -20 "$RUN_DIR/train.log" 2>/dev/null | sed 's/^/A_LOG /'
