#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
if [ -s "$A_STATE_ROOT/agent.pid" ] && kill -0 "$(cat "$A_STATE_ROOT/agent.pid")" 2>/dev/null; then
  echo "incumbent already running" >&2
  exit 1
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$A_STATE_ROOT"
setpriv --reuid="$(id -u "$SERVICE_USER")" --regid="$(id -g "$SERVICE_USER")" --init-groups \
  setsid "$A_PROGRAM" --endpoint "http://$TENANT_HOST:$TENANT_PORT" --branch-key "$BRANCH_KEY" \
  --state-root "$A_STATE_ROOT" --expected-bytes "$A_BYTES" --expected-sha256 "$A_SHA256" \
  >"$A_STATE_ROOT/agent.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_STATE_ROOT/agent.pid"
awk '{print $22}' "/proc/$pid/stat" >"$A_STATE_ROOT/agent.starttime"
awk '{print $5}' "/proc/$pid/stat" >"$A_STATE_ROOT/agent.pgid"
chown "$SERVICE_USER:$SERVICE_USER" "$A_STATE_ROOT/agent.pid" "$A_STATE_ROOT/agent.starttime" "$A_STATE_ROOT/agent.pgid"
echo "INCUMBENT_STARTED=1 pid=$pid"

