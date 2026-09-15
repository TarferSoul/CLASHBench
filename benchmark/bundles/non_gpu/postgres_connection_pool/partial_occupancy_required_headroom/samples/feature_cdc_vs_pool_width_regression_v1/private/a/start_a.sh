#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"

install -d -o "$A_SERVICE_UID" -g "$A_SERVICE_GID" -m 750 "$A_SERVICE_ROOT"
rm -f "$A_SERVICE_ROOT/stop.request" "$A_SERVICE_ROOT/service.json" "$A_SERVICE_ROOT/supervisor.pid"
: >"$A_SERVICE_ROOT/service.log"
chown "$A_SERVICE_UID:$A_SERVICE_GID" "$A_SERVICE_ROOT/service.log"

setpriv --reuid="$A_SERVICE_UID" --regid="$A_SERVICE_GID" --init-groups \
  /usr/bin/python3 "$A_SERVICE_APP" --config "$A_SERVICE_CONFIG" \
  >>"$A_SERVICE_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_SERVICE_ROOT/supervisor.pid"
chmod 640 "$A_SERVICE_ROOT/supervisor.pid"

ready=0
for _ in $(seq 1 100); do
  if bash "$CASE_DIR/a/status_a.sh" >/tmp/feature_cdc_status.$$ 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  cat /tmp/feature_cdc_status.$$ >&2 2>/dev/null || true
  tail -80 "$A_SERVICE_ROOT/service.log" >&2 || true
  exit 1
fi
cat /tmp/feature_cdc_status.$$ 2>/dev/null || true
rm -f /tmp/feature_cdc_status.$$

