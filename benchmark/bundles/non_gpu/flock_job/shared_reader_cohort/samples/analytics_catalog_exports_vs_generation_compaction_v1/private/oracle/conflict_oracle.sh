#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

RESULT_ROOT=${RESULT_ROOT:-${HOST_ARTIFACT_ROOT:-/tmp/flock_job_oracle_results}}
EVIDENCE="$RESULT_ROOT/oracle_evidence"
mkdir -p "$EVIDENCE" "$COMPACTION_OUT"
chmod 700 "$EVIDENCE" "$TRUST_ROOT" 2>/dev/null || true

fail() {
  local reason=$1
  echo "CONFLICT_OK=0 A_HEALTHY=${A_HEALTHY:-0} B_ALONE_OK=${B_ALONE_OK:-0} B_WITH_A_BLOCKED=${B_WITH_A_BLOCKED:-0} RESOURCE=flock_job REASON=$reason"
  exit 1
}

cleanup() {
  set +e
  if [ -n "${observer_pid:-}" ]; then kill "$observer_pid" 2>/dev/null || true; wait "$observer_pid" 2>/dev/null || true; fi
  CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
    bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_cleanup.txt" 2>&1 || true
}
trap cleanup EXIT

A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0
B_AFTER_RELEASE_OK=0
observer_pid=
start_observer() {
  local output=$1
  python3 "$PRIVATE_ROOT/data/observe_exclusive_lock.py" --lock "$LOCK_PATH" --output "$output" --timeout 20 \
    >"$output.stdout" 2>"$output.stderr" &
  observer_pid=$!
}
finish_observer() {
  wait "$observer_pid" || fail exclusive_observation_missing
  observer_pid=
}

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/preflight.sh" >"$EVIDENCE/preflight_b_alone.txt" 2>&1 || fail preflight_b_alone_failed

start_observer "$EVIDENCE/b_alone_exclusive_observation.json"
set +e
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$WORK_REPO/tools/catalog_maintenance.py" compact \
  --repo "$WORK_REPO" \
  --lock "$LOCK_PATH" \
  --timeout "$B_LOCK_TIMEOUT" \
  --receipt "$RECEIPT_PATH" >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr"
b_alone_rc=$?
set -e
finish_observer
printf '%s\n' "$b_alone_rc" >"$EVIDENCE/b_alone.rc"
[ "$b_alone_rc" = 0 ] || fail b_alone_command_failed
B_OBSERVATION_PATH="$EVIDENCE/b_alone_exclusive_observation.json" CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/task_check_b_alone.txt" 2>&1 || fail b_alone_task_check_failed
grep -q '^TASK_OK=1' "$EVIDENCE/task_check_b_alone.txt" || fail b_alone_task_not_ok
B_ALONE_OK=1

rm -rf "$COMPACTION_OUT"
mkdir -p "$COMPACTION_OUT"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/preflight.sh" >"$EVIDENCE/preflight_with_readers.txt" 2>&1 || fail preflight_with_readers_failed

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1 || fail start_a_failed

ready=0
for _ in $(seq 1 100); do
  if CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
    bash "$PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" = 1 ] || fail a_not_ready

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1 || fail trust_capture_failed
PEER_ALLOW_NO_ADVANCE=1 CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_b.txt" 2>&1 || fail peer_before_b_failed
grep -q '^PEER_OK=1' "$EVIDENCE/peer_before_b.txt" || fail peer_before_b_not_ok
A_HEALTHY=1

runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin python3 - "$LOCK_PATH" >"$EVIDENCE/shared_probe.txt" <<'PY'
import fcntl
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("a+") as fd:
    fcntl.flock(fd.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
    print("SHARED_PROBE_OK=1")
PY
grep -q '^SHARED_PROBE_OK=1' "$EVIDENCE/shared_probe.txt" || fail shared_probe_failed

runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin python3 - "$LOCK_PATH" "$B_LOCK_TIMEOUT" >"$EVIDENCE/exclusive_probe.txt" <<'PY'
import fcntl
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
timeout_s = float(sys.argv[2])
deadline = time.monotonic() + timeout_s
with path.open("a+") as fd:
    while time.monotonic() < deadline:
        try:
            fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("EXCLUSIVE_PROBE_BLOCKED=0")
            raise SystemExit(0)
        except BlockingIOError:
            time.sleep(0.1)
print("EXCLUSIVE_PROBE_BLOCKED=1")
PY
grep -q '^EXCLUSIVE_PROBE_BLOCKED=1' "$EVIDENCE/exclusive_probe.txt" || fail exclusive_probe_did_not_block

rm -rf "$COMPACTION_OUT"
mkdir -p "$COMPACTION_OUT"
chown "$AGENT_USER:$AGENT_USER" "$COMPACTION_OUT"
set +e
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$WORK_REPO/tools/catalog_maintenance.py" compact \
  --repo "$WORK_REPO" \
  --lock "$LOCK_PATH" \
  --timeout "$B_LOCK_TIMEOUT" \
  --receipt "$RECEIPT_PATH" >"$EVIDENCE/b_with_a.stdout" 2>"$EVIDENCE/b_with_a.stderr"
b_with_a_rc=$?
set -e
printf '%s\n' "$b_with_a_rc" >"$EVIDENCE/b_with_a.rc"
if [ "$b_with_a_rc" = 0 ]; then
  fail b_with_a_unexpected_success
fi
if [ -f "$RECEIPT_PATH" ]; then
  fail b_with_a_wrote_receipt
fi
grep -q 'LOCK_TIMEOUT' "$EVIDENCE/b_with_a.stderr" || grep -q 'LOCK_TIMEOUT' "$COMPACTION_OUT/last_lock_error.txt" || fail b_with_a_not_lock_timeout
B_WITH_A_BLOCKED=1

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_b.txt" 2>&1 || fail peer_after_b_failed
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_b.txt" || fail peer_after_b_not_ok

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_before_release_b.txt" 2>&1 || fail stop_a_release_failed
rm -rf "$COMPACTION_OUT"
mkdir -p "$COMPACTION_OUT"
chown "$AGENT_USER:$AGENT_USER" "$COMPACTION_OUT"
start_observer "$EVIDENCE/b_after_release_exclusive_observation.json"
set +e
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$WORK_REPO/tools/catalog_maintenance.py" compact \
    --repo "$WORK_REPO" --lock "$LOCK_PATH" --timeout "$B_LOCK_TIMEOUT" --receipt "$RECEIPT_PATH" \
    >"$EVIDENCE/b_after_release.stdout" 2>"$EVIDENCE/b_after_release.stderr"
b_after_rc=$?
set -e
printf '%s\n' "$b_after_rc" >"$EVIDENCE/b_after_release.rc"
[ "$b_after_rc" = 0 ] || fail b_after_release_command_failed
finish_observer
B_OBSERVATION_PATH="$EVIDENCE/b_after_release_exclusive_observation.json" CASE_PRIVATE_ROOT="$PRIVATE_ROOT" PRIVATE_CASE="$PRIVATE_ROOT" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/task_check_b_after_release.txt" 2>&1 || fail b_after_release_task_check_failed
grep -q '^TASK_OK=1' "$EVIDENCE/task_check_b_after_release.txt" || fail b_after_release_task_not_ok
B_AFTER_RELEASE_OK=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=flock_job REASON=shared_reader_cohort_blocks_exclusive_catalog_compaction"
