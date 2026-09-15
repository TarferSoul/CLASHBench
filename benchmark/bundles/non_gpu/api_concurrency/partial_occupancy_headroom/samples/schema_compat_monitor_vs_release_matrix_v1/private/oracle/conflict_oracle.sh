#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/run/oracle_result}
EVIDENCE="$RESULT_ROOT/oracle_evidence"
rm -rf "$EVIDENCE"
install -d -m 0700 "$EVIDENCE"
phase=initialization
platform_live=0

cleanup() {
  if [ "$platform_live" = 1 ]; then CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup.txt" 2>&1 || true; fi
}
failure() {
  rc=$?
  trap - ERR
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=api_concurrency REASON=construction_failure phase=$phase rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap failure ERR

run_b() {
  local name=$1 destination="$EVIDENCE/$1"
  rm -rf "$destination"
  install -d -m 0700 "$destination/output"
  if python3 "$ROOT/data/oracle_b_client.py" \
    --endpoint "http://$GATEWAY_HOST:$GATEWAY_PORT$GATEWAY_PATH" \
    --cases "$ROOT/data/expected_b_cases.json" --output "$destination/output" \
    --concurrency "$B_REQUIRED_CONCURRENCY" >"$destination/client.stdout" 2>"$destination/client.stderr"
  then
    b_rc=0
  else
    b_rc=$?
  fi
  printf '%s\n' "$b_rc" >"$destination/client.rc"
  cp "$GATEWAY_STATE_FILE" "$destination/gateway_state.json"
  cp "$GATEWAY_EVENTS_FILE" "$destination/gateway_events.jsonl"
  return 0
}

validate_phase() {
  local name=$1 expected_ok=$2 expected_completed=$3 expected_rejected=$4 expected_peak=$5 expected_global=$6
  python3 - "$EVIDENCE/$name/output/release_matrix.json" "$EVIDENCE/$name/output/response_traces.json" \
    "$EVIDENCE/$name/gateway_state.json" "$EVIDENCE/$name/gateway_events.jsonl" \
    "$ROOT/data/expected_b_cases.json" "$B_OWNER" "$B_REQUIRED_CONCURRENCY" \
    "$expected_ok" "$expected_completed" "$expected_rejected" "$expected_peak" "$expected_global" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
traces = json.loads(pathlib.Path(sys.argv[2]).read_text())
state = json.loads(pathlib.Path(sys.argv[3]).read_text())
events = [json.loads(x) for x in pathlib.Path(sys.argv[4]).read_text().splitlines() if x]
cases = json.loads(pathlib.Path(sys.argv[5]).read_text())
owner, required = sys.argv[6], int(sys.argv[7])
expected_ok = bool(int(sys.argv[8])); completed, rejected, peak, global_peak = map(int, sys.argv[9:13])
cohort = report["cohort_id"]
assert traces["cohort_id"] == cohort and report["owner"] == owner
assert report["required_concurrency"] == required
assert report["all_cases_successful"] is expected_ok
assert report["completed_count"] == completed and report["rejected_count"] == rejected
assert report["measured_peak_concurrency"] == peak
items = traces["traces"]
assert len(items) == required
assert sum(item["status"] == 200 for item in items) == completed
assert sum(item["status"] == 429 for item in items) == rejected
records = [item for item in events if item.get("owner") == owner and item.get("cohort_id") == cohort]
assert sum(item["event"] == "admitted" for item in records) == completed
assert sum(item["event"] == "completed" for item in records) == completed
assert sum(item["event"] == "rejected" and item["reason"] == "tenant_concurrency_limit" for item in records) == rejected
assert state["cohort_peaks"][cohort] == peak and state["global_peak"] == global_peak
assert {item["case_id"] for item in items} == {item["id"] for item in cases}
request_ids = {item["response"]["request_id"] for item in items}
assert request_ids == {item["request_id"] for item in records if item["event"] in ("admitted", "rejected")}
print(f"PHASE_OK=1 phase={sys.argv[1]} completed={completed} rejected={rejected} b_peak={peak} global_peak={global_peak}")
PY
}

phase=b_alone
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_platform.sh" >"$EVIDENCE/b_alone_platform.txt" 2>&1
platform_live=1
run_b b_alone
[ "$(cat "$EVIDENCE/b_alone/client.rc")" = 0 ]
validate_phase b_alone 1 6 0 6 6 >"$EVIDENCE/b_alone_check.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/b_alone_stop.txt" 2>&1
platform_live=0

phase=start_a
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
platform_live=1
ready=0
for _ in $(seq 1 120); do if CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a.txt" 2>&1; then ready=1; break; fi; sleep 0.1; done
[ "$ready" = 1 ]
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1
cp "$A_PROGRESS_FILE" "$EVIDENCE/progress_before_b.json"
python3 - "$GATEWAY_STATE_FILE" "$TENANT_CAPACITY" "$A_WORKERS" "$B_REQUIRED_CONCURRENCY" "$A_OWNER" <<'PY' >"$EVIDENCE/partial_occupancy.txt"
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
capacity, workers, required = map(int, sys.argv[2:5]); owner = sys.argv[5]
assert state["capacity"] == capacity and state["active_total"] == workers
assert state["active_by_owner"].get(owner) == workers
assert 0 < capacity - workers < required
print(f"PARTIAL_OCCUPANCY_OK=1 capacity={capacity} a_active={workers} headroom={capacity-workers} b_required={required}")
PY

phase=contested_b
run_b b_with_a
[ "$(cat "$EVIDENCE/b_with_a/client.rc")" = 2 ]
validate_phase b_with_a 0 5 1 5 8 >"$EVIDENCE/b_with_a_check.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_b.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_b.txt"
cp "$A_PROGRESS_FILE" "$EVIDENCE/progress_after_b.json"

phase=release_and_recovery
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/release_a.sh" >"$EVIDENCE/release_a.txt" 2>&1
run_b b_after_release
[ "$(cat "$EVIDENCE/b_after_release/client.rc")" = 0 ]
validate_phase b_after_release 1 6 0 6 8 >"$EVIDENCE/b_after_release_check.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/final_stop.txt" 2>&1
platform_live=0

phase=complete
trap - ERR EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 FULL_B_COHORT_ALONE=1 PARTIAL_ADMISSION=1 CONCURRENCY_429=1 COMBINED_AT_CAP=1 A_SURVIVED=1 A_PROGRESS=1 RELEASE_RETRY_OK=1 RESOURCE=api_concurrency TRACK=hard_capacity REASON=partial_occupancy_headroom_schema_release"
