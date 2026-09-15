#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$STATE_DIR" "$EXPORT_DIR" "$(dirname "$LOCK_PATH")"
chmod 700 "$STATE_DIR"
touch "$LOCK_PATH"
rm -f "$STATE_DIR"/*.ready.json "$STATE_DIR"/*.progress.json "$STATE_DIR"/*.done.json "$STATE_DIR"/*.pid "$STATE_DIR"/*.log "$STATE_DIR"/launch.json 2>/dev/null || true

roles=("customer_metrics_export" "billing_quality_export" "lineage_rollup_export")
idx=0
printf '{"workers":[\n' > "$STATE_DIR/launch.json.tmp"
first=1
for worker in $WORKER_IDS; do
  role=${roles[$idx]}
  log="$STATE_DIR/${worker}.log"
  runuser -u "$AGENT_USER" -- env -i \
    HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    nice -n 5 python3 "$A_RUNTIME/export_worker.py" \
    --worker-id "$worker" \
    --role "$role" \
    --repo "$WORK_REPO" \
    --lock "$LOCK_PATH" \
    --state-dir "$STATE_DIR" \
    --export-dir "$EXPORT_DIR" \
    --throttle "$READER_THROTTLE_SECONDS" >"$log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$STATE_DIR/${worker}.pid"
  if [ "$first" = 0 ]; then
    printf ',\n' >> "$STATE_DIR/launch.json.tmp"
  fi
  first=0
  printf '  {"worker_id":"%s","role":"%s","pid":%s,"log":"%s"}' "$worker" "$role" "$pid" "$log" >> "$STATE_DIR/launch.json.tmp"
  idx=$((idx + 1))
done
printf '\n]}\n' >> "$STATE_DIR/launch.json.tmp"
mv "$STATE_DIR/launch.json.tmp" "$STATE_DIR/launch.json"
echo "START_A_OK=1 workers=$WORKER_IDS state_dir=$STATE_DIR export_dir=$EXPORT_DIR lock=$LOCK_PATH"
