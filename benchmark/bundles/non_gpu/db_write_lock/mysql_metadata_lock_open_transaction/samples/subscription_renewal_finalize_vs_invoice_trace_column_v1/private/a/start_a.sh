#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

rm -f "$WORKER_ROOT/worker.pid" "$WORKER_ROOT/worker.state.json" "$WORKER_ROOT/worker.log"
install -d -o "$AGENT_UID" -g "$AGENT_UID" -m 750 "$WORKER_ROOT"
setpriv --reuid="$AGENT_UID" --regid="$AGENT_UID" --init-groups env -i \
  PATH=/usr/bin:/bin HOME="$WORKER_ROOT" MYSQL_SOCKET="$MYSQL_SOCKET" LIVE_DB="$LIVE_DB" \
  WORKER_DB_USER="$WORKER_DB_USER" BATCH_ID="$BATCH_ID" TARGET_ROW_COUNT="$TARGET_ROW_COUNT" \
  VALIDATION_PASSES="$VALIDATION_PASSES" MIN_VALIDATION_SECONDS="$MIN_VALIDATION_SECONDS" \
  WORKER_STATE="$WORKER_ROOT/worker.state.json" setsid "$WORKER_APP" > "$WORKER_ROOT/worker.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$WORKER_ROOT/worker.pid"
chown "$AGENT_UID:$AGENT_UID" "$WORKER_ROOT/worker.pid"

for _ in $(seq 1 300); do
  if [ -s "$WORKER_ROOT/worker.state.json" ]; then
    values=$(/usr/bin/python3 - "$WORKER_ROOT/worker.state.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("validated_count",0),x.get("connection_id",""),x.get("batch_id",""))
PY
)
    read -r phase progress connection_id state_batch <<< "$values"
    if [ "$phase" = validating ] && [ "$progress" -ge "$A_READY_MIN_PROGRESS" ] && [ -n "$connection_id" ] && [ "$state_batch" = "$BATCH_ID" ]; then
      echo "A_READY=1 PID=$pid CONNECTION_ID=$connection_id BATCH_ID=$BATCH_ID PROGRESS=$progress"
      exit 0
    fi
    [ "$phase" != failed ] || break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.05
done
tail -100 "$WORKER_ROOT/worker.log" >&2 || true
echo "A_READY=0" >&2
exit 1
