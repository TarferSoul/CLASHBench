#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
rm -f "$STATE_FILE" "$PID_FILE" "$SERVICE_ROOT/rewrite.log"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$SERVICE_ROOT"
setpriv --reuid="$(id -u "$AGENT_USER")" --regid="$(id -g "$AGENT_USER")" --init-groups \
  env -i PATH=/usr/bin:/bin HOME="$SERVICE_ROOT" PG_SOCKET="$PG_SOCKET" PG_PORT="$PG_PORT" \
  LIVE_DB="$LIVE_DB" A_DB_USER="$A_DB_USER" A_APPLICATION_NAME="$A_APPLICATION_NAME" \
  STATE_FILE="$STATE_FILE" RELEASE_ID="$RELEASE_ID" CLOSEOUT_ID="$CLOSEOUT_ID" \
  STEP_DELAY_SECONDS="${A_STEP_DELAY_OVERRIDE:-$A_STEP_DELAY_SECONDS}" MAX_SECONDS="$A_MAX_SECONDS" \
  setsid "$SERVICE_APP" >"$SERVICE_ROOT/rewrite.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$PID_FILE"; chown "$AGENT_USER:$AGENT_USER" "$PID_FILE"
for _ in $(seq 1 200); do
  if "$ROOT/a/status_a.sh"; then exit 0; fi
  kill -0 "$pid" 2>/dev/null || break; sleep 0.05
done
tail -100 "$SERVICE_ROOT/rewrite.log" >&2 || true
echo "A_READY=0" >&2; exit 1
