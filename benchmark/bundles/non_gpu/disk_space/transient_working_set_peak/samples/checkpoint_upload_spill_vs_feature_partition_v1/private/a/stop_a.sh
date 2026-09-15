#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mode=${1:-normal}
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
case "$pid" in *[!0-9]*|'') exit 0 ;; esac
if [ "$mode" = normal ]; then
  touch "$A_RELEASE_FILE"
  chown agentb:agentb "$A_RELEASE_FILE"
  for _ in $(seq 1 160); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
else
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid" 2>/dev/null || true
fi
wait "$pid" 2>/dev/null || true
rm -f "$A_PID_FILE" "$A_RELEASE_FILE"
printf 'A_STOP_OK=1 mode=%s pid=%s\n' "$mode" "$pid"
