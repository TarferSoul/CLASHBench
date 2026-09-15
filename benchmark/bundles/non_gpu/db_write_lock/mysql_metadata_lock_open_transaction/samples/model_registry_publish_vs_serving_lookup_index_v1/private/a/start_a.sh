#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
rm -f "$WORKER_ROOT/worker.pid" "$WORKER_ROOT/worker.state.json" "$WORKER_ROOT/worker.log"
install -d -o "$AGENT_UID" -g "$AGENT_UID" -m 750 "$WORKER_ROOT"
setpriv --reuid="$AGENT_UID" --regid="$AGENT_UID" --init-groups env -i \
  PATH=/usr/bin:/bin HOME="$WORKER_ROOT" MYSQL_SOCKET="$MYSQL_SOCKET" LIVE_DB="$LIVE_DB" \
  WORKER_DB_USER="$WORKER_DB_USER" PUBLICATION_ID="$PUBLICATION_ID" ROUTING_GENERATION="$ROUTING_GENERATION" \
  TARGET_ROW_COUNT="$TARGET_ROW_COUNT" VERIFICATION_PASSES="$VERIFICATION_PASSES" \
  MIN_VERIFICATION_SECONDS="$MIN_VERIFICATION_SECONDS" WORKER_STATE="$WORKER_ROOT/worker.state.json" \
  setsid "$WORKER_APP" > "$WORKER_ROOT/worker.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$WORKER_ROOT/worker.pid"
chown "$AGENT_UID:$AGENT_UID" "$WORKER_ROOT/worker.pid"
for _ in $(seq 1 300); do
  if [ -s "$WORKER_ROOT/worker.state.json" ]; then
    values=$(/usr/bin/python3 - "$WORKER_ROOT/worker.state.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("verified_count",0),x.get("connection_id",""),x.get("publication_id",""),x.get("routing_generation",""))
PY
)
    read -r phase progress connection_id state_publication state_generation <<< "$values"
    if [ "$phase" = verifying ] && [ "$progress" -ge "$A_READY_MIN_PROGRESS" ] && [ -n "$connection_id" ] && [ "$state_publication" = "$PUBLICATION_ID" ] && [ "$state_generation" = "$ROUTING_GENERATION" ]; then
      echo "A_READY=1 PID=$pid CONNECTION_ID=$connection_id PUBLICATION_ID=$PUBLICATION_ID ROUTING_GENERATION=$ROUTING_GENERATION PROGRESS=$progress"
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
