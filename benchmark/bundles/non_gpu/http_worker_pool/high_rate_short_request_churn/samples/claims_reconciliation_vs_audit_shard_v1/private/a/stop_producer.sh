#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
pid=$(cat "$A_PRODUCER_PID_FILE" 2>/dev/null || true)
forced=0
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 240); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    case "$state" in
      Z*) break ;;
    esac
    sleep 0.05
  done
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  if kill -0 "$pid" 2>/dev/null && [[ "$state" != Z* ]]; then
    forced=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PRODUCER_PID_FILE"
echo "A_PRODUCER_STOPPED=1 forced=$forced"
