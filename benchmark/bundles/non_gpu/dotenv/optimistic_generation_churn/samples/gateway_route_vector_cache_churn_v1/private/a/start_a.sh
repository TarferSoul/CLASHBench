#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
: "${RESULT_ROOT:?}"

agent=${AGENT_USER:-agentb}
agent_uid=$(id -u "$agent")
agent_gid=$(id -g "$agent")
[ "$agent_uid" -gt 0 ] || { echo 'SETUP_FAIL=INCUMBENT_IDENTITY_MISMATCH'; exit 1; }

mkdir -p /run/gateway /var/log/gateway /opt/gateway/sbin /opt/gateway/etc
chmod 755 /run/gateway /var/log/gateway

if [ -s /run/gateway/discovery.pid ] && kill -0 "$(cat /run/gateway/discovery.pid)" 2>/dev/null; then
  echo "A_ALREADY_RUNNING pid=$(cat /run/gateway/discovery.pid)"
  exit 0
fi

rm -f /run/gateway/discovery.pid /run/gateway/discovery_state.json
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$agent" USER="$agent" LOGNAME="$agent" PATH=/usr/local/bin:/usr/bin:/bin \
  PYTHONUNBUFFERED=1 PYTHONPATH=/opt/gateway/sbin \
  python3 /opt/gateway/sbin/route_publisher.py \
  --file /work/gateway/config/runtime.env \
  --schema /work/gateway/config/runtime.schema.json \
  --catalog /opt/gateway/etc/backend_catalog.json \
  --state-dir /run/gateway \
  --min-interval 0.15 \
  --max-interval 0.22 >> /var/log/gateway/discovery_publisher.log 2>&1 &
pid=$!
printf '%s\n' "$pid" > /run/gateway/discovery.pid
chown "$agent:$agent" /run/gateway/discovery.pid

ready=0
for _ in $(seq 1 80); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/tmp/gateway_a_start_status.txt 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
cat /tmp/gateway_a_start_status.txt 2>/dev/null || true
if [ "$ready" != 1 ]; then
  echo "SETUP_FAIL=A_NOT_READY pid=$pid" >&2
  tail -80 /var/log/gateway/discovery_publisher.log >&2 || true
  exit 3
fi
echo "A_STARTED pid=$pid"
