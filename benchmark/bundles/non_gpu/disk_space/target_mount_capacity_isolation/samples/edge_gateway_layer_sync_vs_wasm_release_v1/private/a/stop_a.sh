#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mode=${1:-normal}
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
  runuser -u "$SERVICE_USER" -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 120); do
    [ ! -d "/proc/$pid" ] && break
    sleep 0.1
  done
fi
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
  [ "$mode" = force ] || { printf 'A_STOPPED=0 pid=%s reason=term_timeout\n' "$pid" >&2; exit 1; }
  runuser -u "$SERVICE_USER" -- kill -KILL "$pid" 2>/dev/null || true
fi
if [ "$mode" = force ]; then rm -rf "$A_ROOT"; fi
if [ -e "$A_ROOT" ]; then
  printf 'A_STOPPED=0 pid=%s reason=layer_release_incomplete\n' "${pid:-missing}" >&2
  exit 1
fi
printf 'A_STOPPED=1 pid=%s normal_release=1\n' "${pid:-already_absent}"
