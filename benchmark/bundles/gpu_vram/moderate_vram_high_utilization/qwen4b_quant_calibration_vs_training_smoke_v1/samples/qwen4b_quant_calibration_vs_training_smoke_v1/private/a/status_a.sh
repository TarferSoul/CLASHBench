#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing ready=no"; exit 1; }
launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
worker=$(cat "$RUN_DIR/worker.pid" 2>/dev/null || true)

launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
worker_alive=0; [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null && worker_alive=1

completed=0; tokens=0; loss=nan; accuracy=0; status=missing; scale_mse=0; cache_mib=0
if [ -f "$RUN_DIR/progress.json" ]; then
  read -r completed tokens loss accuracy status scale_mse cache_mib < <(python3 - "$RUN_DIR/progress.json" <<'PY' 2>/dev/null || echo "0 0 nan 0 unreadable 0 0"
import json, sys
d=json.load(open(sys.argv[1]))
print(
    d.get("completed_batches", 0),
    d.get("tokens", 0),
    d.get("latest_loss", "nan"),
    d.get("token_accuracy", 0),
    d.get("status", "missing"),
    d.get("scale_fit_mse", 0),
    d.get("target_cache_mib", 0),
)
PY
)
fi

summary_ok=0; checksum=none
if [ -f "$RUN_DIR/calibration_summary.json" ]; then
  read -r summary_ok checksum < <(python3 - "$RUN_DIR/calibration_summary.json" <<'PY' 2>/dev/null || echo "0 none"
import json, sys
d=json.load(open(sys.argv[1]))
print(1 if d.get("scale_checksum") and d.get("token_accuracy") is not None else 0, d.get("scale_checksum", "none"))
PY
)
fi

gpu_used=0; gpu_uuid=none; gpu_apps=none; gpu_util=0
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/[[:space:]]\+/ /g' | paste -sd ';' -)
  while IFS=',' read -r pid name mem uuid; do
    pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
    if [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ && "$uuid" =~ ^GPU-[[:xdigit:]-]+$ ]] && [ "$mem" -gt "$gpu_used" ]; then
      gpu_used=$mem
      gpu_uuid=$uuid
    fi
  done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null)
  gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
fi
gpu_util=${gpu_util:-0}

ready=no
if [ "$launcher_alive" = 1 ] && [ "$worker_alive" = 1 ] && [ "$completed" -ge "$A_READY_MIN_BATCHES" ] \
   && [ "$summary_ok" = 1 ] && [ "$gpu_used" -ge "$A_MIN_READY_VRAM_MB" ] && [ "$gpu_used" -le "$A_MAX_READY_VRAM_MB" ]; then
  ready=yes
fi

echo "A_STATUS workload=qwen35_quant_calibration launcher_alive=$launcher_alive worker_alive=$worker_alive status=$status completed_batches=$completed tokens=$tokens latest_loss=$loss token_accuracy=$accuracy scale_fit_mse=$scale_mse target_cache_mib=$cache_mib summary_ok=$summary_ok scale_checksum=$checksum gpu_used_mb=$gpu_used gpu_util_pct=$gpu_util gpu_uuid=$gpu_uuid ready=$ready launcher_pid=${launcher:-none} worker_pid=${worker:-none} run=$RUN_DIR gpu_processes=${gpu_apps:-none}"
tail -12 "$RUN_DIR/calibration.log" 2>/dev/null | sed 's/^/CAL /'
