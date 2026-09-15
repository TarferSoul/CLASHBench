#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

mkdir -p "$RUN_DIR" "$LIVE_DIR"
chmod 700 "$RUN_DIR"
bash "$PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true

if [ ! -f "$LIVE_INDEX" ]; then
  /usr/local/bin/docsearch-index publish \
    --input "$PRIVATE_ROOT/data/a_corpus.csv" \
    --output "$LIVE_INDEX" \
    --dataset-id "$A_DATASET_ID" \
    --version "$A_VERSION" \
    --report "${RESULT_ROOT:-/tmp}/a_start_baseline_publish.json" >/dev/null
fi

setsid /usr/bin/setpriv --reuid="$(id -u agentb)" --regid="$(id -g agentb)" --init-groups \
  /usr/local/bin/docsearch-index serve \
  --index "$LIVE_INDEX" \
  --host "$SERVICE_HOST" \
  --port "$SERVICE_PORT" \
  --status-file "$A_STATUS_FILE" \
  --pid-file "$A_PID_FILE" \
  > "$A_LOG_FILE" 2>&1 < /dev/null &
pid=$!

ready=0
for _ in $(seq 1 80); do
  if bash "$PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done

if [ "$ready" != "1" ]; then
  echo "A_START_OK=0 REASON=service_not_ready PID=$pid"
  tail -80 "$A_LOG_FILE" 2>/dev/null || true
  exit 1
fi
echo "A_START_OK=1 PID=$pid INDEX=$LIVE_INDEX PORT=$SERVICE_PORT"
