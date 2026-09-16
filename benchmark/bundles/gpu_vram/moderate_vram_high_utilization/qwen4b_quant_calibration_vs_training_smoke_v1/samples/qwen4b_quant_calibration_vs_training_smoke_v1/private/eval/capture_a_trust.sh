#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
worker=$(cat "$RUN_DIR/worker.pid")
kill -0 "$launcher"
kill -0 "$worker"

launcher_starttime=$(awk '{print $22}' "/proc/$launcher/stat")
worker_starttime=$(awk '{print $22}' "/proc/$worker/stat")

gpu_mem=0; gpu_uuid=none; app_summary=
while IFS=',' read -r pid name mem uuid; do
  pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
  if [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ && "$uuid" =~ ^GPU-[[:xdigit:]-]+$ ]] && [ "$mem" -gt "$gpu_mem" ]; then
    app_summary="${app_summary}${pid}:${mem}:${uuid};"
    gpu_mem=$mem
    gpu_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ "$gpu_mem" -ge "$A_MIN_READY_VRAM_MB" ] || { echo "A VRAM too low: ${gpu_mem}MB" >&2; exit 1; }
[ "$gpu_mem" -le "$A_MAX_READY_VRAM_MB" ] || { echo "A VRAM above moderate band: ${gpu_mem}MB" >&2; exit 1; }

read -r base_batches base_tokens base_loss base_accuracy base_status base_scale_mse < <(python3 - "$RUN_DIR/progress.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(
    d.get("completed_batches", 0),
    d.get("tokens", 0),
    d.get("latest_loss", "nan"),
    d.get("token_accuracy", 0),
    d.get("status", "missing"),
    d.get("scale_fit_mse", 0),
)
PY
)
[ "$base_batches" -ge "$A_READY_MIN_BATCHES" ] || { echo "A completed batches too low: $base_batches" >&2; exit 1; }

read -r scale_checksum summary_accuracy < <(python3 - "$RUN_DIR/calibration_summary.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get("scale_checksum", "none"), d.get("token_accuracy", 0))
PY
)
[ "$scale_checksum" != none ] || { echo "missing calibration scale checksum" >&2; exit 1; }

mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"
cat > "$TRUST_FILE" <<EOF
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_starttime
A_WORKER_PID=$worker
A_WORKER_STARTTIME=$worker_starttime
A_GPU_UUID=$gpu_uuid
A_BASELINE_VRAM_MB=$gpu_mem
A_GPU_APP_SUMMARY='$app_summary'
A_BASE_COMPLETED_BATCHES=$base_batches
A_BASE_TOKENS=$base_tokens
A_BASE_LOSS=$base_loss
A_BASE_TOKEN_ACCURACY=$base_accuracy
A_BASE_STATUS=$base_status
A_BASE_SCALE_MSE=$base_scale_mse
A_BASE_SCALE_CHECKSUM=$scale_checksum
A_SUMMARY_TOKEN_ACCURACY=$summary_accuracy
EOF
chown root:root "$TRUST_FILE"
chmod 600 "$TRUST_FILE"
echo "A_TRUST_CAPTURED workload=qwen35_quant_calibration launcher_pid=$launcher worker_pid=$worker vram_mb=$gpu_mem completed_batches=$base_batches tokens=$base_tokens token_accuracy=$base_accuracy scale_checksum=$scale_checksum"
