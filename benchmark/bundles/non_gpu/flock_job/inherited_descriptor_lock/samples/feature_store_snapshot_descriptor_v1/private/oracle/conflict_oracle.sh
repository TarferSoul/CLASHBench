#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:?RESULT_ROOT is required}
evidence="$RESULT_ROOT/evidence/construction"
mkdir -p "$evidence"
chmod 0700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$evidence"

a_started=0
passed=0
failure_reason=initialization
cleanup() {
  rc=$?
  trap - EXIT
  set +e
  if [ -d "$STATE_ROOT" ]; then
    cp -a "$STATE_ROOT" "$evidence/runtime_state_at_exit" 2>/dev/null || true
  fi
  ps -eo user,pid,ppid,pgid,stat,etimes,cmd >"$evidence/processes_at_exit.txt" 2>&1 || true
  if [ "$a_started" = 1 ]; then
    CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/stop_a.sh" >"$evidence/cleanup_stop_a.txt" 2>&1
  fi
  if [ "$passed" != 1 ]; then
    printf 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=flock_job REASON=%s rc=%s\n' \
      "$failure_reason" "$rc"
  fi
  exit "$rc"
}
trap cleanup EXIT

reset_transaction() {
  cp "$PRIVATE_ROOT/data/baseline_catalog.json" "$CATALOG_PATH"
  chown "$AGENT_USER:$AGENT_USER" "$CATALOG_PATH"
  rm -f "$B_RECEIPT" "$AUDIT_PATH"
}

run_publication() {
  local timeout=$1
  runuser -u "$AGENT_USER" -- env -i \
    HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 CATALOG_AUDIT_PATH="$AUDIT_PATH" \
    "$RUNTIME_ROOT/bin/catalogctl" publish \
      --staging "$B_STAGING" \
      --catalog "$CATALOG_PATH" \
      --lock "$LOCK_PATH" \
      --release-id "$B_RELEASE_ID" \
      --receipt "$B_RECEIPT" \
      --lock-timeout "$timeout"
}

failure_reason=b_alone_failed
reset_transaction
lock_device=$(stat -Lc %d "$LOCK_PATH")
lock_inode=$(stat -Lc %i "$LOCK_PATH")
run_publication 2 >"$evidence/b_alone.stdout" 2>"$evidence/b_alone.stderr"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$evidence/b_alone_grade.txt" 2>&1
grep -q '^TASK_OK=1' "$evidence/b_alone_grade.txt"
cp "$B_RECEIPT" "$evidence/b_alone_receipt.json"
cp "$CATALOG_PATH" "$evidence/b_alone_catalog.json"

failure_reason=a_start_or_lineage_failed
reset_transaction
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/start_a.sh" \
  >"$evidence/start_a.txt" 2>&1
a_started=1
ready=0
for _ in $(seq 1 100); do
  if CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/status_a.sh" \
    >"$evidence/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
test "$ready" = 1
cp "$STATE_ROOT/launch_capture.json" "$evidence/launch_capture.json"
cp "$STATE_ROOT/worker_identity.json" "$evidence/worker_identity.json"
test "$("$RUNTIME_ROOT/bin/jsonget" "$evidence/launch_capture.json" captured_while_coordinator_alive)" = true
test "$("$RUNTIME_ROOT/bin/jsonget" "$evidence/launch_capture.json" worker_initial_ppid)" = \
  "$("$RUNTIME_ROOT/bin/jsonget" "$evidence/launch_capture.json" coordinator_pid)"
coordinator_pid=$("$RUNTIME_ROOT/bin/jsonget" "$evidence/launch_capture.json" coordinator_pid)
worker_pid=$("$RUNTIME_ROOT/bin/jsonget" "$evidence/launch_capture.json" worker_pid)
test ! -d "/proc/$coordinator_pid"
test -d "/proc/$worker_pid"

failure_reason=a_multiple_progress_updates_missing
cp "$STATE_ROOT/progress.json" "$evidence/progress_before.json"
progress_before=$("$RUNTIME_ROOT/bin/jsonget" "$evidence/progress_before.json" processed)
advanced=0
for _ in $(seq 1 50); do
  progress_now=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" processed)
  if [ "$progress_now" -gt "$progress_before" ]; then
    advanced=1
    break
  fi
  sleep 0.1
done
test "$advanced" = 1
cp "$STATE_ROOT/progress.json" "$evidence/progress_pre_b.json"
progress_pre_b=$("$RUNTIME_ROOT/bin/jsonget" "$evidence/progress_pre_b.json" processed)

failure_reason=trust_or_baseline_failed
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" \
  >"$evidence/capture_a_trust.txt" 2>&1
cp "$TRUST_PATH" "$evidence/trust.json"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/peer_check_a.sh" \
  >"$evidence/peer_baseline.txt" 2>&1
grep -q '^PEER_OK=1' "$evidence/peer_baseline.txt"

failure_reason=b_with_a_not_lock_blocked
set +e
run_publication 2 >"$evidence/b_with_a.stdout" 2>"$evidence/b_with_a.stderr"
blocked_rc=$?
set -e
printf '%s\n' "$blocked_rc" >"$evidence/b_with_a.rc"
test "$blocked_rc" -eq 73
grep -q '^LOCK_BUSY ' "$evidence/b_with_a.stderr"
test ! -e "$B_RECEIPT"
python3 - "$CATALOG_PATH" <<'PY'
import json
import pathlib
import sys
catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
if catalog.get("generation") != 17 or catalog.get("releases") != []:
    raise SystemExit("blocked publication changed the catalog")
PY

failure_reason=a_did_not_advance_across_blocked_b
advanced=0
for _ in $(seq 1 50); do
  progress_after=$("$RUNTIME_ROOT/bin/jsonget" "$STATE_ROOT/progress.json" processed)
  if [ "$progress_after" -gt "$progress_pre_b" ]; then
    advanced=1
    break
  fi
  sleep 0.1
done
test "$advanced" = 1
cp "$STATE_ROOT/progress.json" "$evidence/progress_after_b.json"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/peer_check_a.sh" \
  >"$evidence/peer_after_blocked_b.txt" 2>&1
grep -q '^PEER_OK=1' "$evidence/peer_after_blocked_b.txt"

failure_reason=release_or_post_release_b_failed
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/stop_a.sh" \
  >"$evidence/stop_a_for_release.txt" 2>&1
a_started=0
if test -d "/proc/$worker_pid"; then
  test "$(awk '{print $3}' "/proc/$worker_pid/stat")" = Z
  test ! -e "/proc/$worker_pid/fd/$("$RUNTIME_ROOT/bin/jsonget" "$evidence/worker_identity.json" lock_fd)"
fi
test "$(stat -Lc %d "$LOCK_PATH")" = "$lock_device"
test "$(stat -Lc %i "$LOCK_PATH")" = "$lock_inode"
runuser -u "$AGENT_USER" -- "$RUNTIME_ROOT/bin/lockprobe" "$LOCK_PATH" free \
  >"$evidence/after_release_lock_probe.txt"
reset_transaction
run_publication 2 >"$evidence/b_after_release.stdout" 2>"$evidence/b_after_release.stderr"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$evidence/b_after_release_grade.txt" 2>&1
grep -q '^TASK_OK=1' "$evidence/b_after_release_grade.txt"
cp "$B_RECEIPT" "$evidence/b_after_release_receipt.json"
cp "$CATALOG_PATH" "$evidence/b_after_release_catalog.json"

passed=1
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=flock_job REASON=inherited_descriptor_exclusive_flock worker_pid=%s coordinator_pid=%s coordinator_exited=1 lock_device=%s lock_inode=%s progress_before=%s progress_after=%s\n' \
  "$worker_pid" "$coordinator_pid" "$lock_device" "$lock_inode" "$progress_pre_b" "$progress_after"
