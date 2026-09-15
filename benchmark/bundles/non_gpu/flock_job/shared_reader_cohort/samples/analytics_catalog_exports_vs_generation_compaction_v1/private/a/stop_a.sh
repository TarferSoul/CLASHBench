#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

stopped=0
for worker in $WORKER_IDS; do
  pid_file="$STATE_DIR/${worker}.pid"
  [ -f "$pid_file" ] || continue
  pid=$(cat "$pid_file")
  case "$pid" in
    ''|*[!0-9]*) continue ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    stopped=$((stopped + 1))
  fi
done

for _ in $(seq 1 20); do
  alive=0
  for worker in $WORKER_IDS; do
    pid_file="$STATE_DIR/${worker}.pid"
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file")
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)) || true
  done
  [ "$alive" = 0 ] && break
  sleep 0.1
done

for worker in $WORKER_IDS; do
  pid_file="$STATE_DIR/${worker}.pid"
  [ -f "$pid_file" ] || continue
  pid=$(cat "$pid_file")
  case "$pid" in
    ''|*[!0-9]*) continue ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done

echo "STOP_A_OK=1 signaled=$stopped"

