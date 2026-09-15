#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}

if [ -f "$A_RUNTIME/handoff.done" ]; then
  exit 0
fi
mkdir -p "$A_RUNTIME"
touch "$A_RUNTIME/handoff.done" 2>/dev/null || true

if [ -f "$A_RUNTIME/pid" ]; then
  pid=$(cat "$A_RUNTIME/pid")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$pid" 2>/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
