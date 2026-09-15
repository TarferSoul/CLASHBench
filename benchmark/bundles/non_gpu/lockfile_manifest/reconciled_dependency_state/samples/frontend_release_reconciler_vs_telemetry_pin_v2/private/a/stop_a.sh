#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
if [ -n "$CASE_PRIVATE_ROOT" ] && [ -f "$CASE_PRIVATE_ROOT/fixture.env" ]; then
  # shellcheck disable=SC1091
  . "$CASE_PRIVATE_ROOT/fixture.env"
fi
A_RUNTIME=${A_RUNTIME:-${A_RUNTIME_DEFAULT:-/run/frontend_dependency_reconciler}}
pid=$(cat "$A_RUNTIME/pid" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  touch "$A_RUNTIME/handoff.done" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
printf 'A_STOPPED=1 pid=%s\n' "${pid:-none}"

