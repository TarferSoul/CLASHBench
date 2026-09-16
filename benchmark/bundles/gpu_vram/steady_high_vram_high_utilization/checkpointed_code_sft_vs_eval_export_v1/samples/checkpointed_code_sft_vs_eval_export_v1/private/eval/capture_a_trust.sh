#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
kill -0 "$launcher"
launcher_start=$(awk '{print $22}' "/proc/$launcher/stat")
launcher_pgid=$(ps -o pgid= -p "$launcher" | tr -d ' ')
loss_count=$(awk '/\047loss\047:[[:space:]]*[\047\"]?[0-9]|"loss"[[:space:]]*:[[:space:]]*[\047\"]?[0-9]/ { count++ } END { print count + 0 }' "$RUN_DIR/train.log")
checkpoint_count=$(find "$RUN_DIR/$A_TRAIN_OUTPUT_SUBDIR" -maxdepth 3 -type f \( -name 'trainer_state.json' -o -name 'optimizer.pt' -o -name '*.safetensors' \) 2>/dev/null | wc -l | tr -d ' ')
[ "$loss_count" -ge "${A_MIN_LOSS_RECORDS:-1}" ] || { echo "A_TRUST_FAIL loss_records=$loss_count"; exit 1; }

best_pid=
best_mem=0
best_uuid=
while IFS=',' read -r pid mem uuid; do
  pid=${pid// /}
  mem=${mem// /}
  uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  if [ "$mem" -gt "$best_mem" ]; then
    best_pid=$pid
    best_mem=$mem
    best_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ -n "$best_pid" ] || { echo "A_TRUST_FAIL no_gpu_process"; exit 1; }
[ "$best_mem" -ge "${A_MIN_READY_VRAM_MB:-1}" ] || { echo "A_TRUST_FAIL vram_mb=$best_mem floor=${A_MIN_READY_VRAM_MB:-1}"; exit 1; }
gpu_start=unknown
gpu_state=unknown
gpu_pgid=unknown
if [ -r "/proc/$best_pid/stat" ]; then
  gpu_start=$(awk '{print $22}' "/proc/$best_pid/stat")
  gpu_state=$(awk '{print $3}' "/proc/$best_pid/stat")
  gpu_pgid=$(ps -o pgid= -p "$best_pid" 2>/dev/null | tr -d ' ')
fi

mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"
cat > "$A_TRUST_FILE" <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_start
A_LAUNCHER_PGID=$launcher_pgid
A_GPU_NVML_PID=$best_pid
A_GPU_PROC_PID=$best_pid
A_GPU_STARTTIME=$gpu_start
A_GPU_STATE=$gpu_state
A_GPU_PGID=$gpu_pgid
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$best_mem
A_BASELINE_LOSS_COUNT=$loss_count
A_BASELINE_CHECKPOINT_COUNT=$checkpoint_count
EOF
chown root:root "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED launcher_pid=$launcher gpu_pid=$best_pid vram_mb=$best_mem gpu_uuid=$best_uuid loss_records=$loss_count checkpoint_files=$checkpoint_count"
