#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

test "$(id -u)" -eq 0 || { echo "SETUP_FAIL=A_START_NOT_ROOT" >&2; exit 3; }
agent_uid=$(id -u "$AGENT_USER")
test "$agent_uid" -gt 0 || { echo "SETUP_FAIL=A_IDENTITY_INVALID" >&2; exit 3; }
test "$(stat -Lc %u "$LOCK_PATH")" -eq "$agent_uid" || {
  echo "SETUP_FAIL=LOCK_IDENTITY_MISMATCH" >&2
  exit 3
}

if [ -r "$STATE_ROOT/worker_identity.json" ]; then
  old_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pid)
  if test -d "/proc/$old_pid"; then
    echo "SETUP_FAIL=A_ALREADY_RUNNING pid=$old_pid" >&2
    exit 3
  fi
fi
rm -rf "$STATE_ROOT"/* "$A_STAGE_ROOT"/*
chown "$AGENT_USER:$AGENT_USER" "$STATE_ROOT" "$A_STAGE_ROOT"

runuser -u "$AGENT_USER" -- env -i \
  HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$RUNTIME_ROOT/bin/launch_catalog_rebuild.py" \
    --lock "$LOCK_PATH" \
    --expected-uid "$agent_uid" \
    --state-dir "$STATE_ROOT" \
    --input-dir "$A_INPUT_ROOT" \
    --stage-root "$A_STAGE_ROOT" \
    --catalog "$CATALOG_PATH" \
    --record-delay "$A_RECORD_DELAY" \
    --worker "$RUNTIME_ROOT/bin/catalog_worker.py" \
    >"$STATE_ROOT/coordinator.log" 2>&1 &
launcher_wrapper=$!

captured=0
for _ in $(seq 1 100); do
  if [ -s "$STATE_ROOT/lineage.json" ]; then
    coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/lineage.json" coordinator_pid)
    worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/lineage.json" worker_pid)
    if test -d "/proc/$coordinator_pid" && test -d "/proc/$worker_pid"; then
      worker_ppid=$(awk '{print $4}' "/proc/$worker_pid/stat")
      coordinator_uid=$(stat -Lc %u "/proc/$coordinator_pid")
      worker_uid=$(stat -Lc %u "/proc/$worker_pid")
      if [ "$worker_ppid" = "$coordinator_pid" ] && \
         [ "$coordinator_uid" = "$agent_uid" ] && [ "$worker_uid" = "$agent_uid" ]; then
        cp "$STATE_ROOT/lineage.json" "$STATE_ROOT/launch_capture.json"
        captured=1
        break
      fi
    fi
  fi
  sleep 0.05
done
if [ "$captured" != 1 ]; then
  kill "$launcher_wrapper" 2>/dev/null || true
  wait "$launcher_wrapper" 2>/dev/null || true
  echo "SETUP_FAIL=COORDINATOR_WORKER_LINEAGE_NOT_CAPTURED" >&2
  exit 3
fi

set +e
wait "$launcher_wrapper"
launcher_rc=$?
set -e
if [ "$launcher_rc" -ne 0 ]; then
  cat "$STATE_ROOT/coordinator.log" >&2 || true
  echo "SETUP_FAIL=COORDINATOR_HANDOFF_FAILED rc=$launcher_rc" >&2
  exit 3
fi

coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" coordinator_pid)
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" worker_pid)
test ! -d "/proc/$coordinator_pid" || { echo "SETUP_FAIL=COORDINATOR_DID_NOT_EXIT" >&2; exit 3; }
test -d "/proc/$worker_pid" || { echo "SETUP_FAIL=WORKER_DID_NOT_SURVIVE_HANDOFF" >&2; exit 3; }
test "$(stat -Lc %u "/proc/$worker_pid")" = "$agent_uid" || {
  echo "SETUP_FAIL=WORKER_IDENTITY_MISMATCH" >&2
  exit 3
}
runuser -u "$AGENT_USER" -- kill -0 "$worker_pid" || {
  echo "SETUP_FAIL=WORKER_NOT_SIGNAL_CHECKABLE" >&2
  exit 3
}

printf 'A_START_OK coordinator_pid=%s coordinator_exited=1 worker_pid=%s worker_uid=%s lineage_captured=1\n' \
  "$coordinator_pid" "$worker_pid" "$agent_uid"
