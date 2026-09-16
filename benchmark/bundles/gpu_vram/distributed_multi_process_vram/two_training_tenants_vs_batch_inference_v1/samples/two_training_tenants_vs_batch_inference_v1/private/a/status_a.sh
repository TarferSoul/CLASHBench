#!/bin/bash
# One-shot status for the two trainer processes. No long waits.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_STATUS=missing"; exit 1; }

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

loop_seen() {
  local log=$1
  grep -Eiq "Running training|Total optimization steps|Num examples|trainable params|Gradient Accumulation" "$log" 2>/dev/null
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
  done < <(nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null)
  printf '%s %s %s\n' "${best_pid:-0}" "$best_mem" "${best_uuid:-none}"
}

launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
supervisor=$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null || true)
alpha=$(cat "$RUN_DIR/alpha/tenant.pid" 2>/dev/null || true)
beta=$(cat "$RUN_DIR/beta/tenant.pid" 2>/dev/null || true)
launcher_alive=0; [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && launcher_alive=1
supervisor_alive=0; [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null && supervisor_alive=1
alpha_alive=0; [ -n "$alpha" ] && kill -0 "$alpha" 2>/dev/null && alpha_alive=1
beta_alive=0; [ -n "$beta" ] && kill -0 "$beta" 2>/dev/null && beta_alive=1

alpha_log="$RUN_DIR/alpha/train.log"
beta_log="$RUN_DIR/beta/train.log"
alpha_loss=$(loss_count "$alpha_log")
beta_loss=$(loss_count "$beta_log")
alpha_loop=0; loop_seen "$alpha_log" && alpha_loop=1
beta_loop=0; loop_seen "$beta_log" && beta_loop=1

read -r alpha_gpu alpha_mem alpha_uuid < <(gpu_for_label alpha "${alpha:-}")
read -r beta_gpu beta_mem beta_uuid < <(gpu_for_label beta "${beta:-}")

if [ "$alpha_alive" = 1 ] && [ "$beta_alive" = 1 ] \
   && { [ "$alpha_mem" = 0 ] || [ "$beta_mem" = 0 ]; }; then
  mapfile -t nvml_rows < <(
    nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null \
      | awk -F, '{gsub(/ /,"",$1);gsub(/ /,"",$2);gsub(/ /,"",$3);if($1~/^[0-9]+$/&&$2~/^[0-9]+$/)print $2" "$1" "$3}' \
      | sort -nr
  )
  if [ "${#nvml_rows[@]}" = 2 ]; then
    read -r alpha_mem alpha_gpu alpha_uuid <<<"${nvml_rows[0]}"
    read -r beta_mem beta_gpu beta_uuid <<<"${nvml_rows[1]}"
  fi
fi
aggregate_mem=$((alpha_mem + beta_mem))
gpu_count=0
[ "$alpha_gpu" != 0 ] && gpu_count=$((gpu_count + 1))
[ "$beta_gpu" != 0 ] && [ "$beta_gpu" != "$alpha_gpu" ] && gpu_count=$((gpu_count + 1))

memory_ready=0
if [ "$alpha_mem" -ge "$A_ALPHA_MIN_READY_VRAM_MB" ] \
   && [ "$beta_mem" -ge "$A_BETA_MIN_READY_VRAM_MB" ] \
   && [ "$aggregate_mem" -ge "$A_AGGREGATE_MIN_READY_VRAM_MB" ]; then
  memory_ready=1
fi

ready=no
if [ "$launcher_alive" = 1 ] && [ "$supervisor_alive" = 1 ] \
   && [ "$alpha_alive" = 1 ] && [ "$beta_alive" = 1 ] \
   && [ "$alpha_loop" = 1 ] && [ "$beta_loop" = 1 ] \
   && [ "$alpha_loss" -ge 1 ] && [ "$beta_loss" -ge 1 ] \
   && [ "$gpu_count" = 2 ] && [ "$alpha_uuid" = "$beta_uuid" ] \
   && [ "$memory_ready" = 1 ]; then
  ready=yes
fi

echo "A_STATUS mode=two_training_tenants launcher_alive=$launcher_alive supervisor_alive=$supervisor_alive alpha_alive=$alpha_alive beta_alive=$beta_alive alpha_loop=$alpha_loop beta_loop=$beta_loop alpha_loss=$alpha_loss beta_loss=$beta_loss gpu_count=$gpu_count alpha_vram_mb=$alpha_mem beta_vram_mb=$beta_mem aggregate_vram_mb=$aggregate_mem memory_ready=$memory_ready ready=$ready launcher_pid=${launcher:-none} supervisor_pid=${supervisor:-none} alpha_pid=${alpha:-none} beta_pid=${beta:-none} alpha_gpu_pid=$alpha_gpu beta_gpu_pid=$beta_gpu gpu_uuid=${alpha_uuid:-none} run=$RUN_DIR"
tail -5 "$alpha_log" 2>/dev/null | sed 's/^/ALPHA_TRAIN /'
tail -5 "$beta_log" 2>/dev/null | sed 's/^/BETA_TRAIN /'
