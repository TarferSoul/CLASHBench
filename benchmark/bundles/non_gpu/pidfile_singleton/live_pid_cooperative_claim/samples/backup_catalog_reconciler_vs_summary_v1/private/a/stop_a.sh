#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=""
if [ -r "$A_PIDFILE" ]; then pid=$(head -n 1 "$A_PIDFILE" || true); fi
if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ]; then
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" || true)
  if [[ "$cmdline" == *catalog-reconcile* ]] && [[ "$cmdline" == *"--mode daemon"* ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  fi
fi
rm -f "$A_LAUNCHER_FILE"
if [ -r "$A_PIDFILE" ]; then
  current=$(head -n 1 "$A_PIDFILE" || true)
  if [ -z "$pid" ] || [ "$current" = "$pid" ]; then rm -f "$A_PIDFILE"; fi
fi
echo "A_STOPPED=1"
