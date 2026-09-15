#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
if [ -r "$A_PIDFILE" ]; then
  pid=$(tr -cd '0-9' < "$A_PIDFILE")
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    if [[ $cmdline == *"/usr/local/bin/snapshot-dispatch coordinate"* ]]; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
      for _ in $(seq 1 80); do kill -0 "$pid" >/dev/null 2>&1 || break; sleep 0.05; done
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
fi
if [ -r "$A_LAUNCH_PID" ]; then
  launcher=$(tr -cd '0-9' < "$A_LAUNCH_PID")
  [ -z "$launcher" ] || kill "$launcher" >/dev/null 2>&1 || true
fi
rm -f "$A_LAUNCH_PID"
if [ -e "$A_PIDFILE" ]; then
  owner=$(tr -cd '0-9' < "$A_PIDFILE" || true)
  [ -n "$owner" ] && kill -0 "$owner" >/dev/null 2>&1 || rm -f "$A_PIDFILE"
fi
