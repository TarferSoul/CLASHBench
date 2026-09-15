#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

if [ -s "$A_MANAGER_PID_FILE" ]; then
  manager_pid=$(cat "$A_MANAGER_PID_FILE")
  if kill -0 "$manager_pid" 2>/dev/null; then
    manager_pgid=$(cat "$A_MANAGER_PGID_FILE" 2>/dev/null || true)
    if [ -n "$manager_pgid" ]; then kill -TERM "-$manager_pgid" 2>/dev/null || kill -TERM "$manager_pid" 2>/dev/null || true; else kill -TERM "$manager_pid" 2>/dev/null || true; fi
    for _ in $(seq 1 40); do
      kill -0 "$manager_pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$manager_pid" 2>/dev/null; then
      if [ -n "${manager_pgid:-}" ]; then kill -KILL "-$manager_pgid" 2>/dev/null || true; else kill -KILL "$manager_pid" 2>/dev/null || true; fi
    fi
    wait "$manager_pid" 2>/dev/null || true
  fi
fi

rm -f "$A_MANAGER_PID_FILE" "$A_MANAGER_PGID_FILE" "$A_LISTENER_INODE_FILE" "$A_PATH_STAT_FILE" "$A_TRUST_FILE"
if [ -S "$A_SOCKET_PATH" ]; then
  rm -f "$A_SOCKET_PATH"
fi
echo "A_STOPPED=1"
