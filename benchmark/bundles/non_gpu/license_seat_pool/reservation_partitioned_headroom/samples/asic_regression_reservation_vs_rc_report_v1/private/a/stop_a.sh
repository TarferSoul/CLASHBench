#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=0
if test -s "$A_PID_FILE"; then
  pid=$(<"$A_PID_FILE")
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    test ! -d "/proc/$pid" && break
    sleep 0.05
  done
fi
if test -s "$A_LAUNCHER_PID_FILE"; then
  kill -TERM "$(<"$A_LAUNCHER_PID_FILE")" 2>/dev/null || true
fi
if test -s "$MANAGER_PID_FILE"; then
  kill -TERM "$(<"$MANAGER_PID_FILE")" 2>/dev/null || true
  for _ in $(seq 1 40); do
    test ! -S "$MANAGER_SOCKET" && break
    sleep 0.05
  done
fi
printf 'A_STOPPED=1 pid=%s release=normal\n' "$pid"
