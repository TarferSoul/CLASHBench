#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
CLIENT_STATE="$STATE_ROOT/clients"
if [ -d "$CLIENT_STATE" ]; then
  for pid_file in "$CLIENT_STATE"/*.pid; do
    [ -e "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    live=0
    for pid_file in "$CLIENT_STATE"/*.pid; do
      [ -e "$pid_file" ] || continue
      pid=$(cat "$pid_file" 2>/dev/null || true)
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && live=$((live + 1))
    done
    [ "$live" -eq 0 ] && break
    sleep 0.1
  done
  for pid_file in "$CLIENT_STATE"/*.pid; do
    [ -e "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
fi
echo "LOG_CLIENTS_STOPPED=1"

