#!/usr/bin/env bash
set -euo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
STATE_DIR=${A_STATE_DIR:-/var/lib/corpus-prefetch}
PID_FILE="$STATE_DIR/supervisor.pid"
STATE_FILE="$STATE_DIR/state.json"
SERVICE_USER=${SERVICE_USER:-agentb}
PIPELINE=${A_PIPELINE_PATH:-$ROOT/data/run_embedding_export.py}
INPUT=${A_INPUT_PATH:-$ROOT/data/training_corpus.jsonl}

service_group=$(id -gn "$SERVICE_USER")
install -d -o "$SERVICE_USER" -g "$service_group" -m 700 "$STATE_DIR" "$STATE_DIR/output"
if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "A_START=already_running pid=$(cat "$PID_FILE")"
  exit 0
fi
rm -f "$PID_FILE" "$STATE_FILE"
rm -rf "$STATE_DIR/output"
install -d -o "$SERVICE_USER" -g "$service_group" -m 700 "$STATE_DIR/output"
runuser -u "$SERVICE_USER" -- env \
  HOME=/home/$SERVICE_USER USER=$SERVICE_USER LOGNAME=$SERVICE_USER \
  PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  setsid python3 "$PIPELINE" \
  --input "$INPUT" \
  --output-dir "$STATE_DIR/output" \
  --mode continuous \
  --state-file "$STATE_FILE" \
  --namespace live_corpus_sharder \
  --workers "$A_WORKERS" \
  --prefetch-factor "$A_PREFETCH_FACTOR" \
  --batch-size "$A_BATCH_SIZE" \
  --required-items "$A_REQUIRED_ITEMS" \
  --tensor-ratio "$A_TENSOR_RATIO" \
  --consumer-delay "$A_CONSUMER_DELAY" \
  >"$STATE_DIR/service.log" 2>&1 &
launcher_pid=$!
for _ in $(seq 1 100); do
  if [ -s "$STATE_FILE" ]; then
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid" > "$PID_FILE"
      chmod 600 "$PID_FILE"
      echo "A_START=launched pid=$pid launcher=$launcher_pid state=$STATE_FILE user=$SERVICE_USER"
      exit 0
    fi
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
echo "A_START=failed_to_publish_state" >&2
exit 1
