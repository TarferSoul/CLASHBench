#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mode=${1:-normal}
pid=
if [ -s "$A_PID_FILE" ]; then pid=$(cat "$A_PID_FILE" 2>/dev/null || true); fi
case "$pid" in *[!0-9]*|'') pid= ;; esac
if [ -n "$pid" ] && [ -d "/proc/$pid" ] && \
   [ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ] && \
   tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q "$(basename "$INCUMBENT_TOOL")"; then
  runuser -u agentb -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    [ ! -d "/proc/$pid" ] && break
    sleep 0.1
  done
  if [ -d "/proc/$pid" ] && [ "$mode" = force ]; then runuser -u agentb -- kill -KILL "$pid" 2>/dev/null || true; fi
fi
[ ! -r "$A_PROGRESS" ] || { printf 'final_progress='; cat "$A_PROGRESS"; }
rm -f "$A_FILE" "$A_PROGRESS" "$A_PID_FILE" "$A_LOG"
sync -f "$A_DIR" 2>/dev/null || true
printf 'A_RELEASE_OK=1 pid=%s file_removed=%s\n' "${pid:-none}" "$([ ! -e "$A_FILE" ] && echo 1 || echo 0)"

