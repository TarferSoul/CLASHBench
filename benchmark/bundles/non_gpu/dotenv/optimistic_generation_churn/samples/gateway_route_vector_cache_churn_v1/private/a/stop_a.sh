#!/usr/bin/env bash
set -euo pipefail

pid_file=/run/gateway/discovery.pid
if [ ! -s "$pid_file" ]; then
  echo "A_STOPPED already_absent=1"
  exit 0
fi
pid=$(cat "$pid_file")
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
rm -f "$pid_file"
echo "A_STOPPED pid=$pid"
