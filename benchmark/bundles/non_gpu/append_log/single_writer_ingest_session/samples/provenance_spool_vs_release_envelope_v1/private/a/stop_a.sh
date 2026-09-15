#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
for pid_file in "$A_PID_FILE" "$COLLECTOR_PID_FILE"; do
  pid=$(cat "$pid_file" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
done
for _ in $(seq 1 40); do
  alive=0
  for pid_file in "$A_PID_FILE" "$COLLECTOR_PID_FILE"; do
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || alive=1
  done
  [ "$alive" = 0 ] && break
  sleep .05
done
rm -f "$SOCKET_PATH"
