#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || {
  echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH reason=agent_uid_zero'
  exit 1
}

if [ -s "$A_PID_FILE" ]; then
  stale_pid=$(cat "$A_PID_FILE")
  if kill -0 "$stale_pid" 2>/dev/null; then
    echo 'SETUP_FAIL=INCUMBENT_ALREADY_RUNNING'
    exit 1
  fi
fi

install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$A_RUNTIME_DIR"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$A_STATE_DIR"
install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" \
  "$private_root/data/ci_webhook_api.py" "$A_RUNTIME_DIR/webhook_api.py"
: >"$A_LOG_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_LOG_FILE"

setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$A_RUNTIME_DIR/webhook_api.py" --address "$LISTEN_ADDRESS" --port "$LISTEN_PORT" \
  >>"$A_LOG_FILE" 2>&1 &
incumbent_pid=$!
printf '%s\n' "$incumbent_pid" >"$A_PID_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_PID_FILE"

cleanup_failed_start() {
  kill "$incumbent_pid" 2>/dev/null || true
  wait "$incumbent_pid" 2>/dev/null || true
  rm -f "$A_PID_FILE"
}

for _ in $(seq 1 50); do
  if ! kill -0 "$incumbent_pid" 2>/dev/null; then
    cat "$A_LOG_FILE" >&2 || true
    cleanup_failed_start
    echo 'SETUP_FAIL=INCUMBENT_EXITED_DURING_START'
    exit 1
  fi
  incumbent_uid=$(stat -c %u "/proc/$incumbent_pid")
  if [ "$incumbent_uid" != "$agent_uid" ]; then
    cleanup_failed_start
    echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH reason=holder_uid'
    exit 1
  fi
  if CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null 2>&1; then
    runuser -u "$AGENT_USER" -- kill -0 "$incumbent_pid" || {
      cleanup_failed_start
      echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH reason=signal_permission'
      exit 1
    }
    printf 'A_STARTED=1 pid=%s uid=%s address=%s port=%s\n' \
      "$incumbent_pid" "$incumbent_uid" "$LISTEN_ADDRESS" "$LISTEN_PORT"
    exit 0
  fi
  sleep 0.1
done

cat "$A_LOG_FILE" >&2 || true
cleanup_failed_start
echo 'SETUP_FAIL=INCUMBENT_NOT_READY'
exit 1
