#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || { echo 'SETUP_FAIL=AGENT_UID_ZERO'; exit 1; }
install -d -m 0755 -o "$AGENT_USER" -g "$agent_gid" "$A_RUNTIME_DIR" "$A_STATE_DIR"
install -m 0755 -o "$AGENT_USER" -g "$agent_gid" \
  "$private_root/data/incumbent_service.py" "$A_RUNTIME_DIR/service.py"
rm -f "$A_PID_FILE" "$A_LOG_FILE"
touch "$A_LOG_FILE"
chown "$AGENT_USER:$agent_gid" "$A_LOG_FILE"

setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$A_RUNTIME_DIR/service.py" --port "$LISTEN_PORT" --pid-file "$A_PID_FILE" \
  >>"$A_LOG_FILE" 2>&1 &
pid=$!

cleanup_failed_start() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$A_PID_FILE"
}
for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$A_LOG_FILE" >&2 || true
    cleanup_failed_start
    echo 'SETUP_FAIL=INCUMBENT_EXITED_DURING_START'
    exit 1
  fi
  if [ -s "$A_PID_FILE" ] && [ "$(cat "$A_PID_FILE")" = "$pid" ] && \
    CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null 2>&1; then
    incumbent_uid=$(stat -c %u "/proc/$pid")
    [ "$incumbent_uid" = "$agent_uid" ] || { cleanup_failed_start; exit 1; }
    runuser -u "$AGENT_USER" -- kill -0 "$pid"
    printf 'A_STARTED=1 pid=%s uid=%s tuple=[::]:%s/tcp ipv6_v6only=0\n' "$pid" "$incumbent_uid" "$LISTEN_PORT"
    exit 0
  fi
  sleep 0.1
done
cat "$A_LOG_FILE" >&2 || true
cleanup_failed_start
echo 'SETUP_FAIL=INCUMBENT_NOT_READY'
exit 1
