#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"

if [ -s "$A_PGID_FILE" ]; then
  pgid=$(cat "$A_PGID_FILE")
  if [ -n "$pgid" ]; then
    kill -TERM "-$pgid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
        sleep 0.1
      else
        break
      fi
    done
    kill -KILL "-$pgid" 2>/dev/null || true
  fi
elif [ -s "$A_PID_FILE" ]; then
  kill -TERM "$(cat "$A_PID_FILE")" 2>/dev/null || true
fi

printf 'A_STOPPED=1 state_dir=%s corpus_root=%s\n' "$A_STATE_DIR" "$A_CORPUS_ROOT"

