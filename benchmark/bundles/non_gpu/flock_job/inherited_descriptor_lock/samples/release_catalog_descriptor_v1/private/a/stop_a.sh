#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

agent_uid=$(id -u "$AGENT_USER")
test "$agent_uid" -gt 0 || { echo "CLEANUP_FAIL=AGENT_IDENTITY_INVALID" >&2; exit 3; }
if [ ! -r "$STATE_ROOT/worker_identity.json" ]; then
  echo "A_STOP_OK state=not_started"
  exit 0
fi
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pid)
lock_fd=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" lock_fd)
if ! test -d "/proc/$worker_pid"; then
  echo "A_STOP_OK state=already_exited pid=$worker_pid"
  exit 0
fi
incumbent_uid=$(stat -Lc %u "/proc/$worker_pid")
if [ "$incumbent_uid" != "$agent_uid" ]; then
  echo "CLEANUP_FAIL=WORKER_IDENTITY_MISMATCH pid=$worker_pid expected_uid=$agent_uid actual_uid=$incumbent_uid" >&2
  exit 3
fi
runuser -u "$AGENT_USER" -- kill -TERM "$worker_pid"
for _ in $(seq 1 50); do
  if ! test -d "/proc/$worker_pid"; then
    echo "A_STOP_OK pid=$worker_pid signal=TERM state=reaped"
    exit 0
  fi
  worker_state=$(awk '{print $3}' "/proc/$worker_pid/stat")
  if [ "$worker_state" = Z ] && [ ! -e "/proc/$worker_pid/fd/$lock_fd" ]; then
    echo "A_STOP_OK pid=$worker_pid signal=TERM state=zombie_descriptor_closed"
    exit 0
  fi
  sleep 0.1
done
runuser -u "$AGENT_USER" -- kill -KILL "$worker_pid"
for _ in $(seq 1 20); do
  if ! test -d "/proc/$worker_pid"; then
    echo "A_STOP_OK pid=$worker_pid signal=KILL state=reaped"
    exit 0
  fi
  worker_state=$(awk '{print $3}' "/proc/$worker_pid/stat")
  if [ "$worker_state" = Z ] && [ ! -e "/proc/$worker_pid/fd/$lock_fd" ]; then
    echo "A_STOP_OK pid=$worker_pid signal=KILL state=zombie_descriptor_closed"
    exit 0
  fi
  sleep 0.1
done
echo "CLEANUP_FAIL=WORKER_STILL_PRESENT pid=$worker_pid" >&2
exit 3
