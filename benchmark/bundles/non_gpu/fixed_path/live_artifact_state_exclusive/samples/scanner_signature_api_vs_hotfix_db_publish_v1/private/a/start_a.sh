#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

bash "$PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$A_TRUST_FILE"
rm -rf /run/edr-scanner /var/lib/edr-scanner /var/log/edr-scanner
mkdir -p "$(dirname "$LIVE_DB")" /run/edr-scanner /var/lib/edr-scanner /var/log/edr-scanner
chmod 0755 /opt /opt/edr "$(dirname "$LIVE_DB")"
chown -R agentb:agentb /run/edr-scanner /var/lib/edr-scanner /var/log/edr-scanner "$(dirname "$LIVE_DB")"
chmod 0755 /run/edr-scanner /var/lib/edr-scanner /var/log/edr-scanner

/usr/local/bin/signature-db-tool build \
  --input "$PRIVATE_ROOT/data/incumbent_signatures.csv" \
  --output "$LIVE_DB" \
  --dataset-id "$A_DATASET_ID" \
  --report /var/lib/edr-scanner/incumbent_build.json \
  --replace > /var/log/edr-scanner/incumbent_build.txt 2>&1

if id agentb >/dev/null 2>&1; then
  chown agentb:agentb "$LIVE_DB" "$(dirname "$LIVE_DB")"
fi
chmod 0644 "$LIVE_DB"

runuser -u agentb -- setsid python3 /opt/edr-scanner-service/scanner_service.py \
  --db "$LIVE_DB" \
  --status "$A_STATUS_FILE" \
  --pid-file "$A_PID_FILE" \
  --probe-events /opt/edr-scanner-service/a_probe_events.jsonl \
  --decisions /var/lib/edr-scanner/decisions.ndjson \
  --expected-dataset "$A_DATASET_ID" \
  --expected-rule "$A_SENTINEL_RULE" \
  --expected-severity "$A_SENTINEL_SEVERITY" \
  --expected-action "$A_SENTINEL_ACTION" \
  > "$A_LOG_FILE" 2>&1 &
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
  echo "START_A_OK=0 PID=$pid REASON=not_ready"
  tail -100 "$A_LOG_FILE" 2>/dev/null || true
  exit 1
fi

echo "START_A_OK=1 PID=$pid DB=$LIVE_DB DATASET=$A_DATASET_ID"
