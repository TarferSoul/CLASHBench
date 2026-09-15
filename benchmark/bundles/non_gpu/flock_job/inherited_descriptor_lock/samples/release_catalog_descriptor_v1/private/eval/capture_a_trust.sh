#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/status_a.sh" >/dev/null
agent_uid=$(id -u "$AGENT_USER")
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pid)
worker_start=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" start_ticks)
worker_pgid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pgid)
lock_fd=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" lock_fd)
stage_path=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" stage_path)
coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" coordinator_pid)
coordinator_start=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" coordinator_start_ticks)
processed=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" processed)

test ! -d "/proc/$coordinator_pid" || { echo "TRUST_FAIL=COORDINATOR_STILL_PRESENT" >&2; exit 1; }
test "$(stat -Lc %u "/proc/$worker_pid")" = "$agent_uid"
test "$(runuser -u "$AGENT_USER" -- stat -Lc %d "/proc/$worker_pid/fd/$lock_fd")" = "$(stat -Lc %d "$LOCK_PATH")"
test "$(runuser -u "$AGENT_USER" -- stat -Lc %i "/proc/$worker_pid/fd/$lock_fd")" = "$(stat -Lc %i "$LOCK_PATH")"

mkdir -p "$(dirname "$TRUST_PATH")"
chmod 0700 "$(dirname "$TRUST_PATH")"
python3 - "$TRUST_PATH" "$AGENT_USER" "$agent_uid" "$coordinator_pid" \
  "$coordinator_start" "$worker_pid" "$worker_start" "$worker_pgid" "$lock_fd" \
  "$(stat -Lc %d "$LOCK_PATH")" "$(stat -Lc %i "$LOCK_PATH")" "$stage_path" \
  "$(stat -Lc %d "$stage_path")" "$(stat -Lc %i "$stage_path")" "$processed" <<'PY'
import json
import pathlib
import sys
import time

(out, agent_user, agent_uid, coordinator_pid, coordinator_start, worker_pid,
 worker_start, worker_pgid, lock_fd, lock_device, lock_inode, stage_path,
 stage_device, stage_inode, baseline_processed) = sys.argv[1:]
pathlib.Path(out).write_text(json.dumps({
    "schema_version": 1,
    "agent_user": agent_user,
    "agent_uid": int(agent_uid),
    "coordinator_pid": int(coordinator_pid),
    "coordinator_start_ticks": int(coordinator_start),
    "coordinator_expected_exited": True,
    "worker_pid": int(worker_pid),
    "worker_start_ticks": int(worker_start),
    "worker_pgid": int(worker_pgid),
    "lock_fd": int(lock_fd),
    "lock_device": int(lock_device),
    "lock_inode": int(lock_inode),
    "stage_path": stage_path,
    "stage_device": int(stage_device),
    "stage_inode": int(stage_inode),
    "baseline_processed": int(baseline_processed),
    "captured_at_unix": int(time.time()),
}, sort_keys=True, indent=2) + "\n")
PY
chmod 0600 "$TRUST_PATH"

printf 'TRUST_OK worker_pid=%s worker_start_ticks=%s pgid=%s coordinator_pid=%s coordinator_exited=1 lock_device=%s lock_inode=%s baseline_processed=%s\n' \
  "$worker_pid" "$worker_start" "$worker_pgid" "$coordinator_pid" \
  "$(stat -Lc %d "$LOCK_PATH")" "$(stat -Lc %i "$LOCK_PATH")" "$processed"
