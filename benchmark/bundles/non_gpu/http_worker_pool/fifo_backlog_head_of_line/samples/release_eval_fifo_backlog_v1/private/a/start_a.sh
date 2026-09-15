#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONPATH="$INSTALLED_BIN_DIR"
export NO_PROXY=127.0.0.1,localhost
export no_proxy="$NO_PROXY"

rm -rf "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"
install -d -o root -g root -m 700 "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"

python3 "$INSTALLED_BIN_DIR/prepare_eval_inputs.py" \
  --source-root "$EVAL_FIXTURE_ROOT" \
  --manifest "$A_MANIFEST_FILE" \
  --a-total "$A_TOTAL_REQUESTS"

# Root owns fixture preparation, but the actual HTTP service and incumbent
# producer must run as the actionable agent UID.
chown -R "$AGENT_UID:$AGENT_GID" "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"
chmod -R u+rwX,go-rwx "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"

runuser -u "$AGENT_USER" -- env \
  PATH="$PATH" PYTHONPATH="$PYTHONPATH" NO_PROXY="$NO_PROXY" no_proxy="$no_proxy" \
  /bin/bash -c 'exec -a eval-reportd python3 "$@"' eval-reportd \
  "$INSTALLED_BIN_DIR/eval_report_service.py" \
  --host "$SERVICE_HOST" \
  --port "$SERVICE_PORT" \
  --workers "$EVAL_REPORT_WORKERS" \
  --queue-capacity "$EVAL_REPORT_QUEUE_CAPACITY" \
  --source-root "$EVAL_FIXTURE_ROOT" \
  --state-root "$A_STATE_ROOT" \
  --output-root "$A_OUTPUT_ROOT" \
  --pid-file "$A_SERVICE_PID_FILE" \
  --a-service-seconds "$A_SERVICE_SECONDS" \
  --b-service-seconds "$B_SERVICE_SECONDS" \
  --max-wait-seconds "$EVAL_REPORT_MAX_WAIT_SECONDS" \
  >"$A_STATE_ROOT/eval-reportd.log" 2>&1 &

service_launcher=$!
printf '%s\n' "$service_launcher" >"$A_STATE_ROOT/eval-reportd.launcher.pid"

ready=0
for _ in $(seq 1 100); do
  if [ -s "$A_SERVICE_PID_FILE" ] && python3 - "$SERVICE_HOST" "$SERVICE_PORT" >/dev/null 2>&1 <<'PY'
import socket, sys
sock = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=0.2)
sock.close()
PY
  then
    ready=1
    break
  fi
  sleep 0.05
done
[ "$ready" = 1 ] || { echo "A_START_FAIL=service_not_listening"; exit 1; }

runuser -u "$AGENT_USER" -- env \
  PATH="$PATH" PYTHONPATH="$PYTHONPATH" NO_PROXY="$NO_PROXY" no_proxy="$no_proxy" \
  /bin/bash -c 'exec -a nightly-report-client python3 "$@"' nightly-report-client \
  "$INSTALLED_BIN_DIR/nightly_report_client.py" \
  --endpoint "$EVAL_REPORT_ENDPOINT" \
  --manifest "$A_MANIFEST_FILE" \
  --state-root "$A_STATE_ROOT" \
  --pid-file "$A_CLIENT_PID_FILE" \
  --timeout 120 \
  >"$A_STATE_ROOT/nightly-report-client.log" 2>&1 &

client_launcher=$!
printf '%s\n' "$client_launcher" >"$A_STATE_ROOT/nightly-report-client.launcher.pid"
for _ in $(seq 1 50); do
  [ -s "$A_CLIENT_PID_FILE" ] && break
  sleep 0.05
done
[ -s "$A_CLIENT_PID_FILE" ] || { echo "A_START_FAIL=client_pid_missing"; exit 1; }

echo "A_STARTED=1 service_pid=$(cat "$A_SERVICE_PID_FILE") client_pid=$(cat "$A_CLIENT_PID_FILE") endpoint=$EVAL_REPORT_ENDPOINT manifest=$A_TOTAL_REQUESTS"
