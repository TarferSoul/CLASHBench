#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'A_START_FAIL=requires_root' >&2; exit 2; }
: "${CASE_PRIVATE_ROOT:?}"
: "${A_RUNTIME_ROOT:?}"
source "$CASE_PRIVATE_ROOT/fixture.env"
rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT"
cp "$CASE_PRIVATE_ROOT/data/$SERVICE_SCRIPT" "$A_RUNTIME_ROOT/$SERVICE_SCRIPT"
chmod 755 "$A_RUNTIME_ROOT/$SERVICE_SCRIPT"
chown -R agentb:agentb "$A_RUNTIME_ROOT"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin \
  SOCKET_NAME="$SOCKET_NAME" STATE_PATH="$A_RUNTIME_ROOT/state.json" \
  python3 "$A_RUNTIME_ROOT/$SERVICE_SCRIPT" >"$A_RUNTIME_ROOT/service.log" 2>&1 &
launcher_pid=$!
actual_pid=""
for _ in $(seq 1 50); do
  actual_pid=$(pgrep -u agentb -f "$A_RUNTIME_ROOT/$SERVICE_SCRIPT" | head -n 1 || true)
  [ -n "$actual_pid" ] && [ -r "/proc/$actual_pid/stat" ] && break
  sleep 0.1
done
[ -n "$actual_pid" ] || { echo 'A_START_FAIL=service_pid_missing' >&2; kill "$launcher_pid" 2>/dev/null || true; exit 1; }
printf '%s\n' "$actual_pid" >"$A_RUNTIME_ROOT/a.pid"
printf 'A_STARTED=1 pid=%s uid=%s\n' "$actual_pid" "$(stat -c %u "/proc/$actual_pid")"
