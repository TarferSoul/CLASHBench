#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
runtime_user=${A_RUNTIME_USER:-agentb}
id "$runtime_user" >/dev/null
runtime_uid=$(id -u "$runtime_user")
runtime_gid=$(id -g "$runtime_user")
install -d -m 0755 -o root -g root "$A_DEPLOY_DIR"
install -m 0755 -o root -g root "$ROOT/data/http_schema_registry.py" "$A_DEPLOY_DIR/schema_registry.py"
rm -rf "$A_RUN_DIR"
install -d -m 0755 -o "$runtime_uid" -g "$runtime_gid" "$A_RUN_DIR"
printf '%s\n' "$runtime_uid" >"$A_RUN_DIR/runtime_uid"
chown "$runtime_uid:$runtime_gid" "$A_RUN_DIR/runtime_uid"
IFS=, read -r -a workers <<< "$A_WORKER_IDS"
for worker in "${workers[@]}"; do
  runuser -u "$runtime_user" -- setsid python3 "$A_DEPLOY_DIR/schema_registry.py" \
    "$A_HOST" "$A_PORT" "$worker" "$A_RUN_DIR" >"$A_RUN_DIR/${worker}.log" 2>&1 < /dev/null &
done
for worker in "${workers[@]}"; do
  ready=0
  for _ in $(seq 1 60); do
    if [ -s "$A_RUN_DIR/worker_${worker}.ready" ] && [ -s "$A_RUN_DIR/worker_${worker}.pid" ] && [ -s "$A_RUN_DIR/worker_${worker}.socket_inode" ]; then ready=1; break; fi
    sleep 0.1
  done
  [ "$ready" = 1 ] || { bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; exit 1; }
done
printf 'A_STARTED service=%s workers=%s endpoint=%s:%s uid=%s\n' "$A_SERVICE_NAME" "$A_WORKERS" "$A_HOST" "$A_PORT" "$runtime_uid"
