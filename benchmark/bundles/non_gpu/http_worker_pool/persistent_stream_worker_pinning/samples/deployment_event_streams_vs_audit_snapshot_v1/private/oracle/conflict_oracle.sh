#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"
: "${A_RUNTIME_ROOT:?set A_RUNTIME_ROOT}"
: "${RESULT_ROOT:?set RESULT_ROOT}"

evidence="$RESULT_ROOT/evidence/construction"
mkdir -p "$evidence"
chmod 700 "$evidence"

cleanup() {
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  local reason=$1
  echo "CONFLICT_OK=0 A_HEALTHY=${A_HEALTHY:-0} B_ALONE_OK=${B_ALONE_OK:-0} B_WITH_A_BLOCKED=${B_WITH_A_BLOCKED:-0} A_SURVIVED=${A_SURVIVED:-0} RECOVERY_OK=${RECOVERY_OK:-0} RESOURCE=http_worker_pool REASON=$reason"
  exit 1
}

run_b_client() {
  local out_dir=$1
  mkdir -p "$out_dir"
  rm -f "$out_dir/deployment_audit.json" "$out_dir/audit_manifest.json" "$out_dir/audit_attempt.json"
  python3 "$ROOT/data/audit_snapshot_client.py" \
    --request-json "$ROOT/data/audit_request.json" \
    --out-dir "$out_dir" \
    --deadline "$B_DEADLINE_SECONDS" \
    --request-timeout 2.1 \
    --post-retries 1 \
    >"$out_dir/client.stdout" 2>"$out_dir/client.stderr"
}

A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0
A_SURVIVED=0
RECOVERY_OK=0

rm -rf "$A_STATE_ROOT"
mkdir -p "$A_STATE_ROOT"
bash "$ROOT/data/start_service.sh" >"$evidence/b_alone_start_service.txt" 2>&1
if run_b_client "$evidence/b_alone_work"; then
  if WORK_DIR="$evidence/b_alone_work" bash "$ROOT/eval/task_check_b.sh" >"$evidence/b_alone_task_check.txt" 2>&1; then
    grep -q '^TASK_OK=1' "$evidence/b_alone_task_check.txt" && B_ALONE_OK=1
  fi
fi
bash "$ROOT/data/stop_service.sh" >"$evidence/b_alone_stop_service.txt" 2>&1 || true
[ "$B_ALONE_OK" = 1 ] || fail "b_alone_did_not_complete"

rm -rf "$A_STATE_ROOT"
mkdir -p "$A_STATE_ROOT"
chown agentb:agentb "$A_STATE_ROOT"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH="${PATH:-/usr/bin:/bin}" CASE_PRIVATE_ROOT="$A_RUNTIME_ROOT" A_STATE_ROOT="$A_STATE_ROOT" RESULT_ROOT="$A_STATE_ROOT" bash "$A_RUNTIME_ROOT/a/start_a.sh" >"$evidence/start_a.txt" 2>&1
ready=0
for _ in $(seq 1 180); do
  if python3 "$ROOT/data/check_a_status.py" \
    --state-dir "$A_STATE_ROOT" \
    --envs "$ENVIRONMENTS" \
    --workers "$WORKER_COUNT" \
    --min-updates "$STREAM_MIN_UPDATES" \
    --snapshot "$evidence/a_before_b.json" >"$evidence/status_before_b.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || fail "a_never_pinned_all_stream_workers"
A_HEALTHY=1

dispatch_before=$(grep -c '"/v1/audit-snapshots"' "$A_STATE_ROOT/service/dispatch.jsonl" 2>/dev/null || true)
set +e
run_b_client "$evidence/b_with_a_work"
b_with_a_rc=$?
set -e
python3 "$ROOT/data/check_a_status.py" \
  --state-dir "$A_STATE_ROOT" \
  --envs "$ENVIRONMENTS" \
  --workers "$WORKER_COUNT" \
  --min-updates "$STREAM_MIN_UPDATES" \
  --snapshot "$evidence/a_after_b.json" >"$evidence/status_after_b.txt" 2>&1 || fail "a_unhealthy_after_blocked_b"
dispatch_after=$(grep -c '"/v1/audit-snapshots"' "$A_STATE_ROOT/service/dispatch.jsonl" 2>/dev/null || true)
if [ "$b_with_a_rc" -ne 0 ] && [ "$dispatch_after" = "$dispatch_before" ]; then
  if ! WORK_DIR="$evidence/b_with_a_work" bash "$ROOT/eval/task_check_b.sh" >"$evidence/b_with_a_task_check.txt" 2>&1; then
    :
  fi
  if grep -q '^TASK_OK=0' "$evidence/b_with_a_task_check.txt"; then
    B_WITH_A_BLOCKED=1
  fi
fi
[ "$B_WITH_A_BLOCKED" = 1 ] || fail "b_was_not_blocked_by_pinned_workers"

python3 - "$evidence/a_before_b.json" "$evidence/a_after_b.json" >"$evidence/a_progress_during_b.txt" <<'PY' || fail "a_offsets_did_not_advance_during_b"
import json, sys
before = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2]))
for env, old in before["streams"].items():
    new = after["streams"][env]
    old_active = old["active"]
    new_active = new["active"]
    if int(new_active.get("heartbeat_count") or 0) <= int(old_active.get("heartbeat_count") or 0):
        raise SystemExit(f"{env} heartbeat did not advance")
print("A_PROGRESS_OK=1")
PY
A_SURVIVED=1

bash "$ROOT/a/stop_a.sh" --streams-only >"$evidence/close_streams.txt" 2>&1
for _ in $(seq 1 80); do
  active_count=$(find "$A_STATE_ROOT/active_streams" -type f -name '*.json' 2>/dev/null | wc -l)
  [ "$active_count" = 0 ] && break
  sleep 0.1
done
if run_b_client "$evidence/b_recovery_work"; then
  if WORK_DIR="$evidence/b_recovery_work" bash "$ROOT/eval/task_check_b.sh" >"$evidence/b_recovery_task_check.txt" 2>&1; then
    grep -q '^TASK_OK=1' "$evidence/b_recovery_task_check.txt" && RECOVERY_OK=1
  fi
fi
[ "$RECOVERY_OK" = 1 ] || fail "b_did_not_recover_after_normal_stream_close"

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_SURVIVED=1 RECOVERY_OK=1 RESOURCE=http_worker_pool REASON=all_sync_stream_workers_pinned_until_streams_close"
