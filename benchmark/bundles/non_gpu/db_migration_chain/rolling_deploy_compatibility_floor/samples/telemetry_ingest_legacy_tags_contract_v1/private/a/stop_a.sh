#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
[ -s "$TELEMETRY_PID_FILE" ] || exit 0
pid=$(tr -d '[:space:]' <"$TELEMETRY_PID_FILE")
case "$pid" in *[!0-9]*|"") exit 0 ;; esac
if [ -d "/proc/$pid" ]; then
  runuser -u "$AGENT_USER" -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    [ ! -d "/proc/$pid" ] && break
    sleep 0.1
  done
  [ ! -d "/proc/$pid" ] || runuser -u "$AGENT_USER" -- kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$TELEMETRY_PID_FILE"
echo "A_STOPPED=1 pid=$pid"
