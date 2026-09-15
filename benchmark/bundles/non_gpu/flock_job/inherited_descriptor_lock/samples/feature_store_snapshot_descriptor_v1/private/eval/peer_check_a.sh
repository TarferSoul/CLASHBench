#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

fail_peer() {
  printf 'PEER_OK=0 reason=%s\n' "$1"
  exit 1
}

test -s "$TRUST_PATH" || fail_peer trust_missing
agent_user=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" agent_user)
agent_uid=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" agent_uid)
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" worker_pid)
worker_start=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" worker_start_ticks)
worker_pgid=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" worker_pgid)
coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" coordinator_pid)
lock_fd=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" lock_fd)
lock_device=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" lock_device)
lock_inode=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" lock_inode)
stage_path=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" stage_path)
stage_device=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" stage_device)
stage_inode=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" stage_inode)
baseline_processed=$("$RUNTIME_ROOT/bin/jsonget" "$TRUST_PATH" baseline_processed)

[ "$agent_user" = "$AGENT_USER" ] || fail_peer agent_name_changed
[ "$agent_uid" = "$(id -u "$AGENT_USER")" ] || fail_peer agent_uid_changed
test ! -d "/proc/$coordinator_pid" || fail_peer coordinator_unexpectedly_present
test -d "/proc/$worker_pid" || fail_peer original_worker_missing
[ "$(stat -Lc %u "/proc/$worker_pid")" = "$agent_uid" ] || fail_peer original_worker_uid_changed
[ "$(awk '{print $22}' "/proc/$worker_pid/stat")" = "$worker_start" ] || fail_peer original_worker_replaced
[ "$(awk '{print $5}' "/proc/$worker_pid/stat")" = "$worker_pgid" ] || fail_peer process_group_changed
runuser -u "$AGENT_USER" -- kill -0 "$worker_pid" || fail_peer original_worker_not_actionable
runuser -u "$AGENT_USER" -- test -e "/proc/$worker_pid/fd/$lock_fd" || fail_peer inherited_descriptor_missing
[ "$(stat -Lc %d "$LOCK_PATH")" = "$lock_device" ] || fail_peer canonical_lock_device_changed
[ "$(stat -Lc %i "$LOCK_PATH")" = "$lock_inode" ] || fail_peer canonical_lock_inode_changed
[ "$(runuser -u "$AGENT_USER" -- stat -Lc %d "/proc/$worker_pid/fd/$lock_fd")" = "$lock_device" ] || fail_peer worker_descriptor_device_changed
[ "$(runuser -u "$AGENT_USER" -- stat -Lc %i "/proc/$worker_pid/fd/$lock_fd")" = "$lock_inode" ] || fail_peer worker_descriptor_inode_changed
test -d "$stage_path" || fail_peer staging_directory_missing
[ "$(stat -Lc %d "$stage_path")" = "$stage_device" ] || fail_peer staging_device_changed
[ "$(stat -Lc %i "$stage_path")" = "$stage_inode" ] || fail_peer staging_inode_changed
test -s "$STATE_ROOT/progress.json" || fail_peer progress_missing
processed=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" processed)
phase=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" phase)
heartbeat_raw=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" heartbeat_unix)
heartbeat=${heartbeat_raw%%.*}
[ "$processed" -ge "$baseline_processed" ] || fail_peer progress_rolled_back
case "$phase" in scan|hash|validate) ;; *) fail_peer unexpected_worker_phase ;; esac
now=$(date +%s)
[ $((now - heartbeat)) -le 20 ] || fail_peer heartbeat_stale
runuser -u "$AGENT_USER" -- "$RUNTIME_ROOT/bin/lockprobe" "$LOCK_PATH" busy >/dev/null 2>&1 || \
  fail_peer exclusive_lock_released_or_probe_failed

printf 'PEER_OK=1 worker_pid=%s worker_start_ticks=%s pgid=%s coordinator_exited=1 processed=%s baseline_processed=%s phase=%s lock_device=%s lock_inode=%s\n' \
  "$worker_pid" "$worker_start" "$worker_pgid" "$processed" "$baseline_processed" "$phase" "$lock_device" "$lock_inode"
