#!/bin/bash
# Root-owned identity capture after A is ready and before Agent B starts.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")
launcher=$(cat "$RUN_DIR/launcher.pid")
server=$(cat "$RUN_DIR/server.pid")
kill -0 "$launcher"
kill -0 "$server"

# NVML reports a host-namespace PID while /proc exposes container PIDs.  Do
# not compare those two PID namespaces.  Bind A independently to its local
# launcher/server identities and to the sole NVML allocation observed after
# the clean-GPU preflight.
best_pid=; best_mem=0; best_uuid=; gpu_count=0
while IFS=',' read -r pid mem uuid; do
  pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
  [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
  gpu_count=$((gpu_count + 1))
  if [ "$mem" -gt "$best_mem" ]; then
    best_pid=$pid; best_mem=$mem; best_uuid=$uuid
  fi
done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits)

[ "$gpu_count" = 1 ] || { echo "expected exactly one NVML process, got $gpu_count" >&2; exit 1; }
[ "$best_mem" -ge "$A_MIN_READY_VRAM_MB" ] || { echo "A VRAM too low: ${best_mem}MB" >&2; exit 1; }

association=local_server_identity_plus_single_nvml_after_clean_preflight

python - "$A_PORT" >/dev/null <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=3) as response:
    json.load(response)
PY

eval_pid=0; eval_starttime=0; base_started=0; base_completed=0; total=0
if [ "$A_MODE" = atbench ]; then
  eval_pid=$(cat "$RUN_DIR/eval.pid")
  kill -0 "$eval_pid"
  eval_starttime=$(awk '{print $22}' "/proc/$eval_pid/stat")
  read -r base_started base_completed total active success phase < <(python - "$RUN_DIR/atbench_progress.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d['started'], d['completed'], d['total'], d['active'], d['success'], d['phase'])
PY
)
  [ "$base_started" -ge 50 ] && [ "$active" -gt 0 ] && [ "$success" -ge 1 ] && [ "$phase" = running ]
fi

launcher_starttime=$(awk '{print $22}' "/proc/$launcher/stat")
server_starttime=$(awk '{print $22}' "/proc/$server/stat")
mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
cat > /var/cbtrust/gpu_vllm35b_a <<EOF
A_MODE=$A_MODE
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$launcher_starttime
A_SERVER_PID=$server
A_SERVER_STARTTIME=$server_starttime
A_GPU_PID=$best_pid
A_GPU_UUID=$best_uuid
A_BASELINE_VRAM_MB=$best_mem
A_GPU_ASSOCIATION=$association
A_EVAL_PID=$eval_pid
A_EVAL_STARTTIME=$eval_starttime
A_BASE_STARTED=$base_started
A_BASE_COMPLETED=$base_completed
A_EVAL_TOTAL=$total
A_PORT=$A_PORT
EOF
chown root:root /var/cbtrust/gpu_vllm35b_a
chmod 600 /var/cbtrust/gpu_vllm35b_a
echo "A_TRUST_CAPTURED mode=$A_MODE server_pid=$server gpu_nvml_pid=$best_pid gpu_uuid=$best_uuid vram_mb=$best_mem eval_pid=$eval_pid started=$base_started completed=$base_completed association=$association"
