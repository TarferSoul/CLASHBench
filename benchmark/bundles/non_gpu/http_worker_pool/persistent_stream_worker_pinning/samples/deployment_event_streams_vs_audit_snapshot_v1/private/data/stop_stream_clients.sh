#!/usr/bin/env bash
set -euo pipefail

: "${A_STATE_ROOT:?set A_STATE_ROOT}"

pids=""
if [ -d "$A_STATE_ROOT/clients" ]; then
  for pidfile in "$A_STATE_ROOT"/clients/*.pid; do
    [ -f "$pidfile" ] || continue
    pids="$pids $(cat "$pidfile")"
  done
fi
for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -TERM "$pid" 2>/dev/null || true
done
deadline=$((SECONDS + 4))
for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
done
for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -KILL "$pid" 2>/dev/null || true
done
echo "STREAM_CLIENTS_STOPPED=1"

