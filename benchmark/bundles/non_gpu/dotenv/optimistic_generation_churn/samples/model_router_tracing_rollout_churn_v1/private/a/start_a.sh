#!/usr/bin/env bash
set -euo pipefail

PID_FILE=/run/inference-router/rollout.pid
STATUS_FILE=/run/inference-router/rollout.status.json
LOG_FILE=/var/log/inference-router/rollout-controller.log
INTERVAL_MS=${A_PUBLISH_INTERVAL_MS:-240}
agent=${AGENT_USER:-agentb}
agent_uid=$(id -u "$agent")
agent_gid=$(id -g "$agent")
[ "$agent_uid" -gt 0 ] || { echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH'; exit 1; }

mkdir -p /run/inference-router /var/log/inference-router
rm -f "$PID_FILE" "$STATUS_FILE" "$LOG_FILE"

setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$agent" USER="$agent" LOGNAME="$agent" PATH=/usr/local/bin:/usr/bin:/bin \
  PYTHONUNBUFFERED=1 python3 /opt/inference-router/sbin/rollout_controller.py \
  --env /work/inference-router/deploy/router.env \
  --schema /work/inference-router/deploy/router.schema.json \
  --metrics /opt/inference-router/etc/shadow_metrics.json \
  --commit-bin /opt/inference-router/sbin/router_env_commit.py \
  --pid-file "$PID_FILE" \
  --status "$STATUS_FILE" \
  --interval-ms "$INTERVAL_MS" > "$LOG_FILE" 2>&1 &
controller_pid=$!
printf '%s\n' "$controller_pid" > "$PID_FILE.launcher"
chown "$agent:$agent" "$PID_FILE.launcher"

for _ in $(seq 1 60); do
  if [ -s "$PID_FILE" ] && [ -s "$STATUS_FILE" ] && bash "${CASE_PRIVATE_ROOT:?}/a/status_a.sh" >/dev/null 2>&1; then
    status=$(cat "$STATUS_FILE")
    printf 'A_STARTED=1 pid=%s status=%s\n' "$(cat "$PID_FILE")" "$status"
    exit 0
  fi
  if ! kill -0 "$controller_pid" 2>/dev/null; then
    cat "$LOG_FILE" >&2 || true
    echo "A_STARTED=0 controller_exited" >&2
    exit 1
  fi
  sleep 0.1
done

cat "$LOG_FILE" >&2 || true
echo "A_STARTED=0 readiness_timeout" >&2
exit 1
