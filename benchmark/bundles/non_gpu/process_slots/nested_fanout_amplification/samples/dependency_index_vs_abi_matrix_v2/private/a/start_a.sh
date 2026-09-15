#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$A_RUNTIME_ROOT" "$A_DATA_ROOT/state"
chown -R "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_ROOT" "$A_DATA_ROOT"
chmod 0755 "$A_RUNTIME_ROOT" "$A_DATA_ROOT" "$A_DATA_ROOT/state"

if [ -s "$A_RUNTIME_ROOT/service.pid" ]; then
  old_pid=$(cat "$A_RUNTIME_ROOT/service.pid")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "START_A_FAIL=already_running pid=$old_pid" >&2
    exit 1
  fi
fi
find "$A_RUNTIME_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

uid=$(id -u "$A_SERVICE_USER")
gid=$(id -g "$A_SERVICE_USER")
setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
  env HOME="$A_DATA_ROOT" USER="$A_SERVICE_USER" LOGNAME="$A_SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$A_INSTALL_ROOT/index_service.py" \
    --projects "$A_PROJECT_WORKERS" \
    --analyzers "$A_ANALYZERS_PER_WORKER" \
    --seconds "$A_ANALYSIS_SECONDS" \
    --input-root "$A_DATA_ROOT/input" \
    --state-root "$A_RUNTIME_ROOT" \
    --worker-program "$A_INSTALL_ROOT/project_worker.py" \
    --analyzer-program "$A_INSTALL_ROOT/analyze_unit.py" \
  >> "$A_DATA_ROOT/service.log" 2>&1 &
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$A_RUNTIME_ROOT/launcher.pid"
chown "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_ROOT/launcher.pid"

deadline=$((SECONDS + A_READY_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then
    cat "$A_RUNTIME_ROOT/health.json"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    echo "START_A_FAIL=service_exited pid=$launcher_pid" >&2
    tail -n 60 "$A_DATA_ROOT/service.log" >&2 || true
    exit 1
  fi
  sleep 0.1
done
echo "START_A_FAIL=readiness_timeout pid=$launcher_pid" >&2
tail -n 60 "$A_DATA_ROOT/service.log" >&2 || true
exit 1
