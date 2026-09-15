#!/usr/bin/env bash
set -euo pipefail
PID_FILE=/run/voice-qa/a.pid
if [ -s "$PID_FILE" ]; then
  pid=$(cat "$PID_FILE")
  case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true; for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done; kill -9 "$pid" 2>/dev/null || true ;; esac
fi
rm -f "$PID_FILE" /run/voice-qa/a_status.json /run/voice-qa/recorder.log
printf 'A_STOPPED=1\n'
