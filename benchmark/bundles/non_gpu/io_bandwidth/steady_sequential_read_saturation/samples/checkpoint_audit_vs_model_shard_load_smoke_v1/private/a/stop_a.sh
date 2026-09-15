#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}"
if [ -n "$ROOT" ] && [ -f "$ROOT/fixture.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ROOT/fixture.env"
  set +a
else
  A_PID_FILE=${A_PID_FILE:-/run/model_registry_audit_state/audit.pid}
fi

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 reason=no_pid"
  exit 0
fi
pid="$(cat "$A_PID_FILE" 2>/dev/null || true)"
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "A_STOPPED=1 reason=not_running"
  exit 0
fi
pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi
for _ in $(seq 1 50); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 pid=$pid"
    exit 0
  fi
  sleep 0.1
done
if [ -n "${pgid:-}" ]; then
  kill -KILL "-$pgid" 2>/dev/null || true
else
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 pid=$pid forced=1"
