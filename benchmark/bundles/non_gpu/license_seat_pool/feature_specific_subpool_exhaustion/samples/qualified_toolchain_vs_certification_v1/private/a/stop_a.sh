#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if test -s "$A_PID_FILE"; then kill -TERM "$(<"$A_PID_FILE")" 2>/dev/null || true; fi
if test -s "$A_RUNTIME/worker_launcher_pid"; then kill -TERM "$(<"$A_RUNTIME/worker_launcher_pid")" 2>/dev/null || true; fi
for _ in $(seq 1 40); do test ! -d "/proc/$(cat "$A_PID_FILE" 2>/dev/null || echo 0)" && break; sleep .05; done
if test -s "$A_RUNTIME/manager_pid"; then kill -TERM "$(<"$A_RUNTIME/manager_pid")" 2>/dev/null || true; fi
rm -f "$MANAGER_SOCKET" "$A_PID_FILE" "$A_READY_FILE"
printf 'A_STOPPED=1\n'
