#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
for f in "$A_PID_DIR"/*.pid; do [ -f "$f" ] || continue; pid=$(cat "$f"); kill "$pid" 2>/dev/null || true; done
for f in "$A_PID_DIR"/*.pid; do [ -f "$f" ] || continue; pid=$(cat "$f"); for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done; done
for f in "$A_PID_DIR"/*.launcher.pid; do [ -f "$f" ] || continue; pid=$(cat "$f"); kill "$pid" 2>/dev/null || true; done
printf 'A_STOPPED=1\n'
