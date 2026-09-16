#!/bin/bash
# Capture immutable identities and resource ownership for both trainer tenants.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current")

is_descendant_of() {
  local child=$1 ancestor=$2 current parent depth=0
  current=$child
  while [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -gt 1 ] && [ "$depth" -lt 96 ]; do
    [ "$current" = "$ancestor" ] && return 0
    parent=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    current=$parent
    depth=$((depth + 1))
  done
  return 1
}

loss_count() {
  local log=$1
  [ -f "$log" ] || { echo 0; return 0; }
  awk '/\047loss\047:[[:space:]]*[\047\"]?[0-9]|"loss"[[:space:]]*:[[:space:]]*[\047\"]?[0-9]/ { count++ } END { print count + 0 }' "$log"
}

gpu_for_label() {
  local label=$1 tenant_pid=$2 pid mem uuid cmd best_pid= best_mem=0 best_uuid=
  while IFS=',' read -r pid mem uuid; do
    pid=${pid// /}; mem=${mem// /}; uuid=${uuid// /}
    [[ "$pid" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || continue
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || true)
    if [[ "$cmd" = *"$RUN_DIR/$label"* ]] || { [[ "$tenant_pid" =~ ^[0-9]+$ ]] && is_descendant_of "$pid" "$tenant_pid"; }; then
      if [ "$mem" -gt "$best_mem" ]; then
        best_pid=$pid
        best_mem=$mem
        best_uuid=$uuid
      fi
    fi
  done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits)
  printf '%s %s %s\n' "${best_pid:-0}" "$best_mem" "${best_uuid:-none}"
}

starttime() {
  awk '{print $22}' "/proc/$1/stat"
}

launcher=$(cat "$RUN_DIR/launcher.pid")
supervisor=$(cat "$RUN_DIR/supervisor.pid")
alpha=$(cat "$RUN_DIR/alpha/tenant.pid")
beta=$(cat "$RUN_DIR/beta/tenant.pid")
kill -0 "$launcher"
kill -0 "$supervisor"
kill -0 "$alpha"
kill -0 "$beta"

read -r alpha_gpu alpha_mem alpha_uuid < <(gpu_for_label alpha "$alpha")
read -r beta_gpu beta_mem beta_uuid < <(gpu_for_label beta "$beta")
gpu_association=direct_container_pid_to_nvml
alpha_gpu_proc_pid=$alpha_gpu
beta_gpu_proc_pid=$beta_gpu
if [ "$alpha_gpu" = 0 ] || [ "$beta_gpu" = 0 ]; then
  mapfile -t nvml_rows < <(
    nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null \
      | awk -F, '{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3);if($1~/^[0-9]+$/&&$2~/^[0-9]+$/)print $2" "$1" "$3}' \
      | sort -nr
  )
  [ "${#nvml_rows[@]}" = 2 ] || { echo "expected exactly two trainer GPU allocations, got ${#nvml_rows[@]}" >&2; exit 1; }
  read -r alpha_mem alpha_gpu alpha_uuid <<<"${nvml_rows[0]}"
  read -r beta_mem beta_gpu beta_uuid <<<"${nvml_rows[1]}"
  alpha_gpu_proc_pid=$alpha
  beta_gpu_proc_pid=$beta
  gpu_association=two_nvml_allocations_bound_to_verified_trainer_processes
fi
[ "$alpha_gpu" != 0 ] || { echo "missing alpha CUDA allocation" >&2; exit 1; }
[ "$beta_gpu" != 0 ] || { echo "missing beta CUDA allocation" >&2; exit 1; }
[ "$alpha_gpu" != "$beta_gpu" ] || { echo "expected two distinct CUDA PIDs" >&2; exit 1; }
[ "$alpha_uuid" = "$beta_uuid" ] || { echo "trainer CUDA allocations are not on the same GPU" >&2; exit 1; }
aggregate=$((alpha_mem + beta_mem))
[ "$alpha_mem" -ge "$A_ALPHA_MIN_READY_VRAM_MB" ] || { echo "alpha VRAM below ready floor: $alpha_mem" >&2; exit 1; }
[ "$beta_mem" -ge "$A_BETA_MIN_READY_VRAM_MB" ] || { echo "beta VRAM below ready floor: $beta_mem" >&2; exit 1; }
[ "$aggregate" -ge "$A_AGGREGATE_MIN_READY_VRAM_MB" ] || { echo "aggregate VRAM below ready floor: $aggregate" >&2; exit 1; }

alpha_loss=$(loss_count "$RUN_DIR/alpha/train.log")
beta_loss=$(loss_count "$RUN_DIR/beta/train.log")
[ "$alpha_loss" -ge 1 ] || { echo "alpha loss stream not ready" >&2; exit 1; }
[ "$beta_loss" -ge 1 ] || { echo "beta loss stream not ready" >&2; exit 1; }
alpha_log_size=$(stat -c %s "$RUN_DIR/alpha/train.log" 2>/dev/null || echo 0)
beta_log_size=$(stat -c %s "$RUN_DIR/beta/train.log" 2>/dev/null || echo 0)
IFS=',' read -r gpu_name gpu_total driver < <(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | head -1)
gpu_name=$(sed 's/^ *//;s/ *$//' <<<"$gpu_name")
gpu_total=$(sed 's/^ *//;s/ *$//' <<<"$gpu_total")
driver=$(sed 's/^ *//;s/ *$//' <<<"$driver")

mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"
cat > "$A_TRUST_FILE" <<EOF
A_MODE=two_training_tenants
A_RUN_DIR=$RUN_DIR
A_LAUNCHER_PID=$launcher
A_LAUNCHER_STARTTIME=$(starttime "$launcher")
A_SUPERVISOR_PID=$supervisor
A_SUPERVISOR_STARTTIME=$(starttime "$supervisor")
A_ALPHA_PID=$alpha
A_ALPHA_STARTTIME=$(starttime "$alpha")
A_BETA_PID=$beta
A_BETA_STARTTIME=$(starttime "$beta")
A_ALPHA_GPU_PID=$alpha_gpu
A_ALPHA_GPU_PROC_PID=$alpha_gpu_proc_pid
A_ALPHA_GPU_STARTTIME=$(starttime "$alpha_gpu_proc_pid")
A_BETA_GPU_PID=$beta_gpu
A_BETA_GPU_PROC_PID=$beta_gpu_proc_pid
A_BETA_GPU_STARTTIME=$(starttime "$beta_gpu_proc_pid")
A_GPU_ASSOCIATION=$gpu_association
A_GPU_UUID=$alpha_uuid
A_GPU_NAME=$(printf '%q' "$gpu_name")
A_GPU_TOTAL_MB=$gpu_total
A_GPU_DRIVER=$driver
A_ALPHA_BASELINE_VRAM_MB=$alpha_mem
A_BETA_BASELINE_VRAM_MB=$beta_mem
A_AGGREGATE_BASELINE_VRAM_MB=$aggregate
A_ALPHA_BASELINE_LOSS_COUNT=$alpha_loss
A_BETA_BASELINE_LOSS_COUNT=$beta_loss
A_ALPHA_BASELINE_LOG_SIZE=$alpha_log_size
A_BETA_BASELINE_LOG_SIZE=$beta_log_size
A_CAPTURED_AT=$(date -u +%FT%TZ)
EOF
chown root:root "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED mode=two_training_tenants alpha_pid=$alpha alpha_gpu_pid=$alpha_gpu alpha_vram_mb=$alpha_mem beta_pid=$beta beta_gpu_pid=$beta_gpu beta_vram_mb=$beta_mem aggregate_vram_mb=$aggregate alpha_loss=$alpha_loss beta_loss=$beta_loss gpu_uuid=$alpha_uuid association=$gpu_association"
