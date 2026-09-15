#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

stop_pid_file() {
  local pid_file=$1 label=$2
  if [ ! -s "$pid_file" ]; then
    return 0
  fi
  local pid
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file"
        echo "STOPPED label=$label pid=$pid"
        return 0
      fi
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  echo "STOPPED label=$label pid=$pid"
}

scope=${STOP_SCOPE:-all}
case "$scope" in
  replicator|all) ;;
  *) echo "unknown STOP_SCOPE=$scope" >&2; exit 2 ;;
esac

touch "$A_STATE_ROOT/stop_replicator" 2>/dev/null || true
if [ "$scope" = replicator ] || [ "$scope" = all ]; then
  stop_pid_file "$A_STATE_ROOT/replicator.pid" replicator
fi
if [ "$scope" = all ]; then
  stop_pid_file "$A_STATE_ROOT/relay.pid" relay
  stop_pid_file "$A_STATE_ROOT/backend.pid" backend
fi

