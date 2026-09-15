#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

mkdir -p "$RESULT_ROOT/evidence/phases" "$RESULT_ROOT/grades"
chmod 700 "$RESULT_ROOT/evidence" "$RESULT_ROOT/evidence/phases" "$RESULT_ROOT/grades"

step=initialization
gateway_started=0
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
  if [ "$gateway_started" = 1 ]; then
    bash "$ROOT/platform/stop_gateway.sh" >"$RESULT_ROOT/evidence/stop_gateway_cleanup.txt" 2>&1 || true
  fi
}

on_error() {
  local rc=$?
  trap - ERR
  echo "CONFLICT_OK=0 RESOURCE=api_concurrency REASON=sdk_contract_oracle_failed step=$step rc=$rc"
  exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

run_b_command() {
  local phase=$1
  rm -rf "$B_OUTPUT_ROOT"
  mkdir -p "$B_OUTPUT_ROOT"
  set +e
  (
    cd /work
    SDK_SCHEMA_BASE_URL="$SDK_SCHEMA_BASE_URL" \
    SDK_SCHEMA_METRICS_URL="$SDK_SCHEMA_METRICS_URL" \
    SDK_SCHEMA_OWNER="$B_OWNER" \
    SDK_SCHEMA_RUN_ID="$B_RUN_ID" \
    B_REQUEST_TIMEOUT_MS="$B_REQUEST_TIMEOUT_MS" \
    PATH="/work/bin:/opt/node/bin:$FIXED_PATH" \
      node tools/validate-structured-output.mjs \
        --fixtures fixtures/structured_output_regressions.jsonl \
        --deployment "$MODEL_ID" \
        --tenant "$TENANT_ID" \
        --concurrency "$B_REQUIRED_CONCURRENCY" \
        --trace-dir "$B_TRACE_DIR" \
        --report "$B_REPORT"
  ) >"$RESULT_ROOT/evidence/${phase}_b.stdout" 2>"$RESULT_ROOT/evidence/${phase}_b.stderr"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$RESULT_ROOT/evidence/${phase}_b.rc"
  mkdir -p "$RESULT_ROOT/evidence/phases/$phase"
  cp -a "$B_OUTPUT_ROOT/." "$RESULT_ROOT/evidence/phases/$phase/" 2>/dev/null || true
  return "$rc"
}

capture_metrics() {
  local output=$1
  python3 - "$A_HOST" "$A_PORT" >"$output" <<'PY'
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    print(json.dumps(json.load(response), indent=2, sort_keys=True))
PY
}

wait_for_release() {
  for _ in $(seq 1 100); do
    active=$(python3 - "$A_HOST" "$A_PORT" "$A_OWNER_PREFIX" "$A_SHARDS" <<'PY'
import json
import sys
import urllib.request
host, port, prefix, shards = sys.argv[1:]
shards = int(shards)
try:
    with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
        metrics = json.load(response)
    active = sum(int(metrics.get("active_by_owner", {}).get(f"{prefix}-{index}", 0)) for index in range(shards))
except Exception:
    active = -1
print(active)
PY
)
    if [ "$active" = 0 ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

step=preflight
CASE_PUBLIC_ROOT="${CASE_PUBLIC_ROOT:-/work}" bash "$ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight.txt" 2>&1

step=start_gateway_for_b_alone
bash "$ROOT/platform/start_gateway.sh" >"$RESULT_ROOT/evidence/start_gateway_b_alone.txt" 2>&1
gateway_started=1
bash "$ROOT/platform/status_gateway.sh" >"$RESULT_ROOT/evidence/status_gateway_b_alone.txt" 2>&1

step=b_alone
run_b_command b_alone
bash "$ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/grades/b_alone_task_check.txt" 2>&1
grep -q '^TASK_OK=1 ' "$RESULT_ROOT/grades/b_alone_task_check.txt"

step=reset_gateway_for_contested_trial
bash "$ROOT/platform/stop_gateway.sh" >"$RESULT_ROOT/evidence/stop_gateway_after_b_alone.txt" 2>&1
gateway_started=0
bash "$ROOT/platform/start_gateway.sh" >"$RESULT_ROOT/evidence/start_gateway_contested.txt" 2>&1
gateway_started=1
bash "$ROOT/platform/status_gateway.sh" >"$RESULT_ROOT/evidence/status_gateway_contested.txt" 2>&1

step=start_a
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
a_started=1
A_STATUS_SNAPSHOT="$RESULT_ROOT/evidence/status_a_ready_snapshot.json" bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_ready.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_baseline.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_baseline.txt"
capture_metrics "$RESULT_ROOT/evidence/metrics_before_b.json"

step=contested_b
if run_b_command b_with_a; then
  true
fi
python3 - "$B_REPORT" "$A_HOST" "$A_PORT" "$B_OWNER" "$B_RUN_ID" "$B_REQUIRED_CONCURRENCY" "$TENANT_ID" "$MODEL_ID" >"$RESULT_ROOT/evidence/b_with_a_check.txt" <<'PY'
import json
import pathlib
import sys
import urllib.request

report_path, host, port, owner, run_id, required, tenant, deployment = sys.argv[1:]
required = int(required)
report = json.loads(pathlib.Path(report_path).read_text())
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
key = f"{owner}/{run_id}"
denied = int(metrics.get("rejected_by_key", {}).get(key, 0) or 0)
peak = int(metrics.get("peak_active_by_key", {}).get(key, 0) or 0)
completed = int(metrics.get("completed_by_key", {}).get(key, 0) or 0)
failures = report.get("failures") or []
resource_errors = [
    item for item in failures
    if item.get("status") == 429 and item.get("code") == "tenant_concurrency_exceeded"
]
blocked = (
    denied > 0
    and len(resource_errors) > 0
    and peak < required
    and report.get("complete") is not True
    and report.get("tenant") == tenant
    and report.get("deployment") == deployment
    and 0 < completed < int(report.get("total_fixtures", 0))
)
assert blocked
print(
    f"B_WITH_A_BLOCKED=1 denied={denied} peak={peak} required={required} "
    f"completed={completed} resource_errors={len(resource_errors)} failed={len(failures)}"
)
PY
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after_b.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_b.txt"
capture_metrics "$RESULT_ROOT/evidence/metrics_after_b.json"

step=release_control
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
a_started=0
wait_for_release
run_b_command b_after_release
bash "$ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/grades/b_after_release_task_check.txt" 2>&1
grep -q '^TASK_OK=1 ' "$RESULT_ROOT/grades/b_after_release_task_check.txt"
bash "$ROOT/platform/stop_gateway.sh" >"$RESULT_ROOT/evidence/stop_gateway.txt" 2>&1
gateway_started=0

step=complete
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 TENANT_ADMISSION_FAILURE=1 ALL_A_SHARDS_ATTRIBUTED=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 RELEASE_RETRY_OK=1 RESOURCE=api_concurrency REASON=distributed_worker_aggregation"
