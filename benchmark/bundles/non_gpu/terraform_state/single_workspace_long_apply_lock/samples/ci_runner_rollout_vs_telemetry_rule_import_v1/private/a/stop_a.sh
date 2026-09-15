#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ' || true)
  if [[ "$pgid" =~ ^[0-9]+$ ]]; then
    kill -TERM "-$pgid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "-$pgid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
fi

rm -f "$A_PID_FILE" "$A_START_FILE"
echo "A_STOPPED pid=${pid:-none}"

