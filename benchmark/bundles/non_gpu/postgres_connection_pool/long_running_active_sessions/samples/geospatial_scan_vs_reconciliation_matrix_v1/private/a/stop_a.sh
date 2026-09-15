#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

mkdir -p "$SERVICE_ROOT"
touch "$A_STOP_FILE"
if [ -s "$SERVICE_PIDFILE" ]; then
  pid=$(cat "$SERVICE_PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 80); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
fi

pkill -u "$SERVICE_USER" -f "$SERVICE_APP" >/dev/null 2>&1 || true
echo "A_STOPPED=1"
