#!/usr/bin/env bash
set -euo pipefail

PID_FILE=/run/inference-router/rollout.pid
if [ ! -s "$PID_FILE" ]; then
  exit 0
fi
pid=$(cat "$PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      exit 0
    fi
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
fi
