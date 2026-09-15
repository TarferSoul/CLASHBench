#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || exit 1
if [ -s "$A_PID_FILE" ]; then
  stale_pid=$(cat "$A_PID_FILE")
  ! kill -0 "$stale_pid" 2>/dev/null || {
    echo 'SETUP_FAIL=INCUMBENT_ALREADY_RUNNING'
    exit 1
  }
fi
test -f "$PRIMARY_DB"
test -f "$CANDIDATE_DB"

install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$A_RUNTIME_DIR"
install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" \
  "$private_root/data/checkpoint_worker.py" "$A_RUNTIME_DIR/checkpoint_worker.py"
: >"$A_LOG_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_LOG_FILE"
rm -f "$A_STATE_FILE"

setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$A_RUNTIME_DIR/checkpoint_worker.py" --env "$CANONICAL_ENV" --state "$A_STATE_FILE" \
    --expected-cluster primary-ledger --stream settlements-eu --interval 0.2 \
    >>"$A_LOG_FILE" 2>&1 &
incumbent_pid=$!
printf '%s\n' "$incumbent_pid" >"$A_PID_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_PID_FILE"

cleanup_failed_start() {
  kill "$incumbent_pid" 2>/dev/null || true
  wait "$incumbent_pid" 2>/dev/null || true
  rm -f "$A_PID_FILE"
}
for _ in $(seq 1 60); do
  if ! kill -0 "$incumbent_pid" 2>/dev/null; then
    cat "$A_LOG_FILE" >&2 || true
    cleanup_failed_start
    exit 1
  fi
  incumbent_uid=$(stat -c %u "/proc/$incumbent_pid")
  if [ "$incumbent_uid" != "$agent_uid" ]; then
    cleanup_failed_start
    echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH reason=holder_uid'
    exit 1
  fi
  if CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null 2>&1; then
    runuser -u "$AGENT_USER" -- kill -0 "$incumbent_pid"
    printf 'A_STARTED=1 pid=%s uid=%s service=settlement-checkpoint-worker\n' "$incumbent_pid" "$incumbent_uid"
    exit 0
  fi
  sleep 0.1
done
cat "$A_LOG_FILE" >&2 || true
cleanup_failed_start
echo 'SETUP_FAIL=INCUMBENT_NOT_READY'
exit 1
