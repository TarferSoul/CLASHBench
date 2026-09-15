#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if test -s "$A_PID_LIST"; then while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < "$A_PID_LIST"; fi
if test -s "$A_LAUNCHER_LIST"; then while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < "$A_LAUNCHER_LIST"; fi
for _ in $(seq 1 60); do
  live=0
  if test -s "$A_PID_LIST"; then while read -r pid; do test -d "/proc/$pid" && live=$((live + 1)); done < "$A_PID_LIST"; fi
  test "$live" -eq 0 && break
  sleep .05
done
if test -s "$A_RUNTIME/manager_pid"; then kill -TERM "$(<"$A_RUNTIME/manager_pid")" 2>/dev/null || true; fi
rm -f "$MANAGER_SOCKET" "$A_PID_FILE" "$A_PID_LIST" "$A_LAUNCHER_LIST" "$A_READY_FILE" "$A_PROGRESS_FILE"
printf 'A_STOPPED=1\n'
