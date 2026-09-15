#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"

[ "$(id -u)" -eq 0 ]
if [ -f "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo "schema index service already running" >&2
  exit 1
fi
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 >/dev/null
install -d -o root -g root -m 755 /opt/schema-index
install -o root -g root -m 755 "$ROOT/a/index_service.py" /opt/schema-index/index_service.py
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
rm -f "$A_PID_FILE" "$A_REAPER_PID_FILE" "$A_EXIT_FILE"
: > "$A_RUNTIME_ROOT/service.log"
chown "$SERVICE_UID:$SERVICE_GID" "$A_RUNTIME_ROOT/service.log"

(
  set +e
  prlimit --nproc="$NPROC_LIMIT:$NPROC_LIMIT" -- \
    setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
    env -i HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH="$FIXED_PATH" \
    python3 /opt/schema-index/index_service.py \
      --source "$A_SOURCE_ROOT" --state "$A_STATE_ROOT" --workers "$A_WORKERS" \
      --uid "$SERVICE_UID" --limit "$NPROC_LIMIT" --pid-file "$A_PID_FILE"
  rc=$?
  printf '%s\n' "$rc" > "$A_EXIT_FILE"
  exit "$rc"
) >> "$A_RUNTIME_ROOT/service.log" 2>&1 &
reaper_pid=$!
printf '%s\n' "$reaper_pid" > "$A_REAPER_PID_FILE"

for _ in $(seq 1 240); do
  if "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED=1 supervisor_pid=$(cat "$A_PID_FILE") workers=$A_WORKERS uid=$SERVICE_UID reaper_pid=$reaper_pid"
    exit 0
  fi
  if ! kill -0 "$reaper_pid" 2>/dev/null; then
    cat "$A_RUNTIME_ROOT/service.log" >&2
    exit 1
  fi
  sleep 0.05
done
cat "$A_RUNTIME_ROOT/service.log" >&2
if [ -f "$A_PID_FILE" ]; then
  kill -TERM "$(cat "$A_PID_FILE")" 2>/dev/null || true
fi
echo "schema index service readiness timeout" >&2
exit 1
