#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

IFS=',' read -r -a replicas <<< "$REPLICA_NAMES"
for replica in "${replicas[@]}"; do
  if [ -s "$SERVICE_ROOT/$replica.pid" ]; then
    pid=$(cat "$SERVICE_ROOT/$replica.pid")
    if kill -0 "$pid" 2>/dev/null; then
      touch "$SERVICE_ROOT/$replica.stop"
      chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_ROOT/$replica.stop"
    fi
  fi
done

for _ in $(seq 1 120); do
  alive=0
  for replica in "${replicas[@]}"; do
    if [ -s "$SERVICE_ROOT/$replica.pid" ]; then
      pid=$(cat "$SERVICE_ROOT/$replica.pid")
      kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
    fi
  done
  [ "$alive" = 0 ] && exit 0
  sleep 0.1
done

for replica in "${replicas[@]}"; do
  [ -s "$SERVICE_ROOT/$replica.pid" ] || continue
  pid=$(cat "$SERVICE_ROOT/$replica.pid")
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
done
for _ in $(seq 1 50); do
  alive=0
  for replica in "${replicas[@]}"; do
    [ -s "$SERVICE_ROOT/$replica.pid" ] || continue
    pid=$(cat "$SERVICE_ROOT/$replica.pid")
    kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
  done
  [ "$alive" = 0 ] && exit 0
  sleep 0.1
done
for replica in "${replicas[@]}"; do
  [ -s "$SERVICE_ROOT/$replica.pid" ] || continue
  pid=$(cat "$SERVICE_ROOT/$replica.pid")
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
done
