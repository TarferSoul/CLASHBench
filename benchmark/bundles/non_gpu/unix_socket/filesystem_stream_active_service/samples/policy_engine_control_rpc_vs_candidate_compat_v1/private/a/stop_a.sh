#!/usr/bin/env bash
set -u
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

pid=""
[ -s "$A_PID_FILE" ] && pid=$(cat "$A_PID_FILE")
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PID_FILE" "$A_FD_INODE_FILE" "$A_PATH_INODE_FILE" "$A_GENERATION_FILE"
if [ -S "$A_SOCKET_PATH" ]; then
  rm -f "$A_SOCKET_PATH"
fi
echo "A_STOPPED=1 pid=${pid:-none}"

