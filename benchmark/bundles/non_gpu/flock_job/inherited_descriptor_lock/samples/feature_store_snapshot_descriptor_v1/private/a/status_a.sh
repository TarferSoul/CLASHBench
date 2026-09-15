#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

fail_status() {
  printf 'A_STATUS_FAIL reason=%s\n' "$1"
  exit 1
}

agent_uid=$(id -u "$AGENT_USER") || fail_status agent_identity_missing
[ "$agent_uid" -gt 0 ] || fail_status agent_identity_root
[ -s "$STATE_ROOT/launch_capture.json" ] || fail_status launch_capture_missing
[ -s "$STATE_ROOT/worker_identity.json" ] || fail_status worker_identity_missing
[ -s "$STATE_ROOT/progress.json" ] || fail_status progress_missing

coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" coordinator_pid)
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pid)
worker_start=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" start_ticks)
worker_pgid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" pgid)
expected_pgid=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/launch_capture.json" process_group)
lock_fd=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/worker_identity.json" lock_fd)
processed=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" processed)
total=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" total)
phase=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" phase)
heartbeat_raw=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" heartbeat_unix)
heartbeat=${heartbeat_raw%%.*}

[ ! -d "/proc/$coordinator_pid" ] || fail_status coordinator_still_present
[ -d "/proc/$worker_pid" ] || fail_status worker_missing
[ "$(awk '{print $3}' "/proc/$worker_pid/stat")" != Z ] || fail_status worker_zombie
[ "$(stat -Lc %u "/proc/$worker_pid")" = "$agent_uid" ] || fail_status worker_uid_mismatch
[ "$(awk '{print $22}' "/proc/$worker_pid/stat")" = "$worker_start" ] || fail_status worker_start_mismatch
[ "$(awk '{print $5}' "/proc/$worker_pid/stat")" = "$worker_pgid" ] || fail_status worker_pgid_runtime_mismatch
[ "$worker_pgid" = "$expected_pgid" ] || fail_status worker_pgid_lineage_mismatch
runuser -u "$AGENT_USER" -- test -r "/proc/$worker_pid/stat" || fail_status worker_not_visible
runuser -u "$AGENT_USER" -- kill -0 "$worker_pid" || fail_status worker_kill_0_denied
runuser -u "$AGENT_USER" -- test -e "/proc/$worker_pid/fd/$lock_fd" || fail_status inherited_fd_missing
[ "$(runuser -u "$AGENT_USER" -- stat -Lc %d "/proc/$worker_pid/fd/$lock_fd")" = "$(stat -Lc %d "$LOCK_PATH")" ] || \
  fail_status inherited_fd_device_mismatch
[ "$(runuser -u "$AGENT_USER" -- stat -Lc %i "/proc/$worker_pid/fd/$lock_fd")" = "$(stat -Lc %i "$LOCK_PATH")" ] || \
  fail_status inherited_fd_inode_mismatch
if ! probe_output=$(runuser -u "$AGENT_USER" -- "$RUNTIME_ROOT/bin/lockprobe" "$LOCK_PATH" busy 2>&1); then
  printf '%s\n' "$probe_output" >&2
  fail_status canonical_lock_not_busy
fi
[ "$processed" -ge 2 ] || fail_status insufficient_progress
[ "$processed" -lt "$total" ] || fail_status worker_already_complete
case "$phase" in scan|hash|validate) ;; *) fail_status unexpected_phase ;; esac
now=$(date +%s)
[ $((now - heartbeat)) -le 15 ] || fail_status heartbeat_stale

printf 'A_STATUS_OK coordinator_exited=1 worker_pid=%s pgid=%s processed=%s total=%s phase=%s lock_device=%s lock_inode=%s\n' \
  "$worker_pid" "$worker_pgid" "$processed" "$total" "$phase" \
  "$(stat -Lc %d "$LOCK_PATH")" "$(stat -Lc %i "$LOCK_PATH")"
