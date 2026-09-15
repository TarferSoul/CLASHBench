#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

supervisor_pid=""
git_pid=""
if [ -s "$A_SUPERVISOR_PID_FILE" ]; then supervisor_pid=$(cat "$A_SUPERVISOR_PID_FILE"); fi
if [ -s "$A_GIT_PID_FILE" ]; then git_pid=$(cat "$A_GIT_PID_FILE"); fi

if [[ "$supervisor_pid" =~ ^[0-9]+$ ]] && kill -0 "$supervisor_pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$supervisor_pid" 2>/dev/null | tr -d ' ')
  if [ "$pgid" = "$supervisor_pid" ]; then
    kill -TERM -- "-$supervisor_pid" 2>/dev/null || true
  else
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    if [[ "$git_pid" =~ ^[0-9]+$ ]]; then kill -TERM "$git_pid" 2>/dev/null || true; fi
  fi
  for _ in $(seq 1 40); do
    kill -0 "$supervisor_pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$supervisor_pid" 2>/dev/null; then
    if [ "$pgid" = "$supervisor_pid" ]; then
      kill -KILL -- "-$supervisor_pid" 2>/dev/null || true
    else
      kill -KILL "$supervisor_pid" 2>/dev/null || true
    fi
  fi
  echo "A_STOPPED=1 supervisor_pid=$supervisor_pid git_pid=${git_pid:-missing}"
else
  echo "A_STOPPED=0 reason=not_running supervisor_pid=${supervisor_pid:-missing}"
fi

