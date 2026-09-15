#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"

if [ ! -r "$CONTROL_ROOT/trusted.env" ]; then
  SMOKE_ROOT="$ROOT" bash "$ROOT/preflight.sh" >/dev/null
fi
. "$CONTROL_ROOT/trusted.env"

mkdir -p "$A_RUN_ROOT" "$HEALTH_DIR" "$RELEASE_ROOT"
mkdir -p /usr/local/libexec
install -o root -g root -m 755 "$ROOT/a/release_mirror.py" /usr/local/libexec/gateway-release-mirror
runuser -u agentb -- env HOME=/home/agentb git config --global --replace-all safe.directory "$REMOTE_REPO"
chown agentb:agentb "$LAB_ROOT" "$RELEASE_ROOT" "$A_RUN_ROOT" "$HEALTH_DIR"
chmod 755 "$LAB_ROOT" "$RELEASE_ROOT"
chmod 700 "$A_RUN_ROOT" "$HEALTH_DIR"
run_dir=$(mktemp -d "$A_RUN_ROOT/run.XXXXXX")
chmod 700 "$run_dir"
chown agentb:agentb "$run_dir"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH="$FIXED_PATH" \
  python3 /usr/local/libexec/gateway-release-mirror "$REMOTE_REPO" "$DESIRED_REF" \
  "$TRUSTED_COMMIT" "$RELEASE_ROOT" "$CURRENT_LINK" "$HEALTH_DIR" \
  "$PUBLISH_PERIOD_SECONDS" >"$run_dir/mirror.log" 2>&1 &
launcher_pid=$!
pid=""
for _ in $(seq 1 100); do
  pid=$(awk -F= '$1=="pid" {print $2}' "$HEALTH_DIR/mirror.env" 2>/dev/null || true)
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && break
  sleep 0.1
done
[ -n "$pid" ] && [ -d "/proc/$pid" ] || {
  kill "$launcher_pid" 2>/dev/null || true
  echo "SETUP_FAIL=INCUMBENT_START_PID_MISSING"
  exit 3
}
printf '%s\n' "$pid" >"$run_dir/mirror.pid"
printf '%s\n' "$launcher_pid" >"$run_dir/launcher.pid"
ln -sfn "$run_dir" "$A_RUN_ROOT/current"
incumbent_uid=$(stat -c %u "/proc/$pid")
echo "A_STARTED=1 pid=$pid incumbent_uid=$incumbent_uid run_dir=$run_dir ref=$DESIRED_REF commit=$TRUSTED_COMMIT period=$PUBLISH_PERIOD_SECONDS"
