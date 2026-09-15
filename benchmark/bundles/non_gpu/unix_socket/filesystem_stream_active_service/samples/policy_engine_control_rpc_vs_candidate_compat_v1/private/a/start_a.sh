#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
: "${A_RUNTIME_ROOT:?set A_RUNTIME_ROOT}"
. "$CASE_DIR/fixture.env"

bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
mkdir -p "$SOCKET_DIR" "$A_STATE_DIR" "$A_RUNTIME_ROOT" "$(dirname "$A_LOG_FILE")" /var/cbtrust
chmod 0777 "$SOCKET_DIR"
chown -R agentb:agentb "$STATE_DIR" "$A_RUNTIME_ROOT"
chmod 0700 "$STATE_DIR" "$A_STATE_DIR" "$A_RUNTIME_ROOT" /var/cbtrust
install -o agentb -g agentb -m 0755 "$CASE_DIR/data/policy_engine_daemon.py" "$A_RUNTIME_ROOT/policy_engine_daemon.py"
install -o agentb -g agentb -m 0644 "$CASE_DIR/data/incumbent_policy_bundle.json" "$A_RUNTIME_ROOT/incumbent_policy_bundle.json"

rm -f "$A_PID_FILE" "$A_FD_INODE_FILE" "$A_PATH_INODE_FILE" \
  "$A_GENERATION_FILE" "$A_STATE_FILE" "$A_JOURNAL" "$A_LOG_FILE" "$SOCKET_PATH"
install -o agentb -g agentb -m 0644 /dev/null "$A_LOG_FILE"

runuser -u agentb -- setsid python3 -u "$A_RUNTIME_ROOT/policy_engine_daemon.py" \
  --socket "$A_SOCKET_PATH" \
  --bundle "$A_BUNDLE" \
  --state-file "$A_STATE_FILE" \
  --journal "$A_JOURNAL" \
  --pid-file "$A_PID_FILE" \
  --fd-inode-file "$A_FD_INODE_FILE" \
  --path-inode-file "$A_PATH_INODE_FILE" \
  --generation-file "$A_GENERATION_FILE" \
  --service-name "$A_SERVICE_NAME" \
  --policy-version "$A_POLICY_VERSION" \
  --generation-token "$A_GENERATION_TOKEN" \
  >>"$A_LOG_FILE" 2>&1 &

printf 'A_LAUNCHED=1 socket=%s\n' "$A_SOCKET_PATH"

ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
if [ "$ready" != 1 ]; then
  echo "A_START_FAILED=1 reason=pid_not_ready" >&2
  tail -80 "$A_LOG_FILE" >&2 || true
  exit 1
fi
