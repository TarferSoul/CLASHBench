#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$A_RUNTIME_ROOT"; install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$A_RUNTIME_ROOT"
touch "$A_LOG_FILE"; chown "$AGENT_USER:$AGENT_USER" "$A_LOG_FILE"
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH="$FIXED_PATH" LANG=C.UTF-8 \
  setsid "$A_APP" --socket "$PG_SOCKET" --port "$PG_PORT" --database "$PG_DATABASE" --user "$PG_ROLE" --state-file "$A_STATE_FILE" >>"$A_LOG_FILE" 2>&1 &
for _ in $(seq 1 "$A_READY_TIMEOUT_TENTHS"); do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then bash "$ROOT/a/status_a.sh"; exit 0; fi
  sleep 0.1
done
echo 'A_READY=0 reason=reindex_native_progress_not_observed' >&2; tail -100 "$A_LOG_FILE" >&2 || true; exit 1
