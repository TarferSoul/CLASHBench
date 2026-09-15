#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
bash "$ROOT/a/start_endpoints.sh"
if [ -s "$A_RUNTIME_ROOT/sender.pid" ] && kill -0 "$(cat "$A_RUNTIME_ROOT/sender.pid")" 2>/dev/null; then echo "relay sender already running" >&2; exit 1; fi
agent_uid=$(id -u "$SERVICE_USER")
agent_gid=$(id -g "$SERVICE_USER")
setsid setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups --reset-env -- \
  env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
  python3 "$A_SENDER_PROGRAM" --host "$LINK_HOST" --port "$LINK_PORT" --state "$A_RUNTIME_ROOT/sender.json" --rate-bps "$UDP_TARGET_BPS" --packet-bytes "$UDP_PACKET_BYTES" --budget "$LINK_BUDGET_PATH" >"$A_RUNTIME_ROOT/sender.log" 2>&1 &
sender_pid=$!; printf '%s\n' "$sender_pid" >"$A_RUNTIME_ROOT/sender.pid"
for _ in $(seq 1 40); do
  [ -r "/proc/$sender_pid/stat" ] || { sleep 0.05; continue; }
  [ "$(stat -c %u "/proc/$sender_pid")" = "$agent_uid" ] && break
  sleep 0.05
done
[ "$(stat -c %u "/proc/$sender_pid")" = "$agent_uid" ] || { echo "A_START_FAIL=wrong_sender_uid pid=$sender_pid" >&2; exit 1; }
awk '{print $22}' "/proc/$sender_pid/stat" >"$A_RUNTIME_ROOT/sender.starttime"
awk '{print $5}' "/proc/$sender_pid/stat" >"$A_RUNTIME_ROOT/sender.pgid"
echo "A_STARTED=1 SENDER_PID=$sender_pid RECEIVER_PID=$(cat "$A_RUNTIME_ROOT/receiver.pid") SERVER_PID=$(cat "$A_RUNTIME_ROOT/server.pid")"
