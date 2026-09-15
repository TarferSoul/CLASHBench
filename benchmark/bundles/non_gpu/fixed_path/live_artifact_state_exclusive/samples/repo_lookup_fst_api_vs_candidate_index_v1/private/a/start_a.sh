#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
. "$CASE_PRIVATE_ROOT/fixture.env"

mkdir -p "$(dirname "$LIVE_INDEX")" "$(dirname "$SERVICE_PID_FILE")" "$(dirname "$SERVICE_LOG")"

if [ -s "$SERVICE_PID_FILE" ] && kill -0 "$(cat "$SERVICE_PID_FILE")" 2>/dev/null; then
  exit 0
fi

/usr/local/bin/repo-index-tool build \
  --input "$A_CORPUS" \
  --output "$LIVE_INDEX" \
  --dataset-id "$A_DATASET_ID" \
  --schema-version 3 \
  --revision "$A_REVISION" \
  --report "${RESULT_ROOT:-/tmp}/a_baseline_publish.json" >/dev/null
chmod 0644 "$LIVE_INDEX"

runuser -u agentb -- setsid python3 /opt/repo-lookup-service/live_lookup_service.py \
  --index "$LIVE_INDEX" \
  --manifest /opt/repo-lookup-service/incumbent_manifest.json \
  --state "$SERVICE_STATE" \
  --pid-file "$SERVICE_PID_FILE" \
  --interval 0.2 >>"$SERVICE_LOG" 2>&1 &
pid=$!

for _ in $(seq 1 80); do
  if "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED=1 PID=$pid"
    exit 0
  fi
  sleep 0.1
done

echo "A_STARTED=0 reason=not_ready PID=$pid" >&2
tail -100 "$SERVICE_LOG" 2>/dev/null || true
exit 1
