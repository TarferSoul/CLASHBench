#!/usr/bin/env bash
set -u

pid=""
if test -s "${A_PID_FILE:-}"; then pid=$(tr -cd '0-9' <"$A_PID_FILE"); fi
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "${A_PID_FILE:-}" "${A_STATE_FILE:-}"
printf 'A_STOPPED=1 pid=%s\n' "$pid"
