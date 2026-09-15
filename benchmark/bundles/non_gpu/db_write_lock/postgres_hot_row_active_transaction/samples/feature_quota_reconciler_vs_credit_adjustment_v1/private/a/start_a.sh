#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

rm -f "$STATE_FILE" "$PID_FILE" "$SERVICE_ROOT/reconcile.log"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$SERVICE_ROOT"
setpriv --reuid="$(id -u "$AGENT_USER")" --regid="$(id -g "$AGENT_USER")" --init-groups \
  env -i PATH=/usr/bin:/bin HOME="$SERVICE_ROOT" \
  PG_SOCKET="$PG_SOCKET" PG_PORT="$PG_PORT" LIVE_DB="$LIVE_DB" A_DB_USER="$A_DB_USER" \
  A_APPLICATION_NAME="$A_APPLICATION_NAME" TENANT_ID="$TENANT_ID" \
  RECONCILE_RUN_ID="$RECONCILE_RUN_ID" METER_WINDOW="$METER_WINDOW" \
  STEP_DELAY_SECONDS="${A_STEP_DELAY_OVERRIDE:-$A_STEP_DELAY_SECONDS}" \
  STATE_FILE="$STATE_FILE" setsid "$SERVICE_APP" >"$SERVICE_ROOT/reconcile.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$PID_FILE"
chown "$AGENT_USER:$AGENT_USER" "$PID_FILE"
for _ in $(seq 1 240); do
  if [ -s "$STATE_FILE" ]; then
    values=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
print(x.get("phase",""),x.get("progress_token",0),x.get("backend_pid",""),x.get("transaction_id",""))
PY
)
    read -r phase progress backend_pid transaction_id <<<"$values"
    if [ "$phase" = validating_meter_window ] && [ "$progress" -ge "$A_READY_MIN_PROGRESS" ] \
        && [ -n "$backend_pid" ] && [ -n "$transaction_id" ]; then
      echo "A_READY=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id RUN_ID=$RECONCILE_RUN_ID PHASE=$phase PROGRESS=$progress"
      exit 0
    fi
    [ "$phase" != failed ] || break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.05
done
tail -100 "$SERVICE_ROOT/reconcile.log" >&2 || true
echo "A_READY=0" >&2
exit 1
