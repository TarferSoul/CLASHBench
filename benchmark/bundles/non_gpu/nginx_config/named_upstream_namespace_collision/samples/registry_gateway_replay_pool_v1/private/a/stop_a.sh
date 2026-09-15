#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

stop_pid_file() {
  local file=$1
  if [ ! -s "$file" ]; then
    return 0
  fi
  local pid
  pid=$(cat "$file" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

stop_pid_file "$A_PREFIX/run/nginx.pid"
stop_pid_file "$A_PREFIX/run/evaluator_a.pid"
stop_pid_file "$A_PREFIX/run/evaluator_b.pid"
rm -rf "$TRUST_ROOT"
echo "A_STOPPED=1"

