#!/bin/bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence/phases" /work/construction
chmod 700 "$RESULT_ROOT/evidence" "$RESULT_ROOT/evidence/phases"

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
  echo "CONFLICT_OK=0 RESOURCE=api_concurrency REASON=continuously_replenished_batch_failed step=$step rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap on_error ERR

run_probe() {
  local output=$1 owner=$2 run_id=$3
  python3 "$ROOT/oracle/b_probe.py" \
    --host "$A_HOST" --port "$A_PORT" --model "$MODEL_ID" \
    --owner "$owner" --run-id "$run_id" \
    --cases "$ROOT/data/$B_CASE_FILE" --concurrency "$B_REQUIRED_CONCURRENCY" \
    --output "$output"
}

snapshot_metrics() {
  local output=$1
  python3 - "$A_HOST" "$A_PORT" "$output" <<'PY'
import json
import pathlib
import sys
import urllib.request
host, port, output = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    payload = json.load(response)
pathlib.Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

step=preflight
bash "$ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight.txt" 2>&1

step=start_gateway
bash "$ROOT/platform/start_gateway.sh" >"$RESULT_ROOT/evidence/start_gateway.txt" 2>&1
gateway_started=1
bash "$ROOT/platform/status_gateway.sh" >"$RESULT_ROOT/evidence/status_gateway.txt" 2>&1

step=b_alone_full_cohort
run_probe /work/construction/b_alone/results.json "$B_RUN_ID-alone" alone \
  >"$RESULT_ROOT/evidence/b_alone.stdout" 2>"$RESULT_ROOT/evidence/b_alone.stderr"
python3 - /work/construction/b_alone/results.json "$B_REQUIRED_CONCURRENCY" <<'PY' >"$RESULT_ROOT/evidence/b_alone_check.txt"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = int(sys.argv[2])
assert payload["all_success"] is True
assert payload["success_count"] == required and payload["denial_count"] == 0
assert payload["correct_count"] == required and payload["aggregate_accuracy"] == 1.0
assert payload["measured_peak_concurrency"] >= required
assert all(item["status"] == 200 for item in payload["responses"])
print(f"B_ALONE_OK=1 success={payload['success_count']} peak={payload['measured_peak_concurrency']} required={required}")
PY
cp -a /work/construction/b_alone "$RESULT_ROOT/evidence/phases/b_alone"

step=start_productive_a
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
a_started=1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a.txt" 2>&1

step=wait_for_a_capacity
occupied=0
for _ in $(seq 1 160); do
  if python3 - "$A_HOST" "$A_PORT" "$GATEWAY_CAPACITY" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request
host, port, capacity = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
a_active = sum(count for owner, count in metrics["active_by_owner"].items() if owner.startswith("embedding-drift-"))
raise SystemExit(0 if a_active == int(capacity) else 1)
PY
  then
    occupied=1
    break
  fi
  sleep 0.025
done
[ "$occupied" = 1 ]
snapshot_metrics "$RESULT_ROOT/evidence/metrics_a_full_before_b.json"
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1

step=b_with_a_admission_denied
run_probe /work/construction/b_with_a/results.json "$B_RUN_ID-contested" contested \
  >"$RESULT_ROOT/evidence/b_with_a.stdout" 2>"$RESULT_ROOT/evidence/b_with_a.stderr"
python3 - /work/construction/b_with_a/results.json "$B_REQUIRED_CONCURRENCY" <<'PY' >"$RESULT_ROOT/evidence/b_with_a_check.txt"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = int(sys.argv[2])
assert payload["all_success"] is False
assert payload["success_count"] < required
assert payload["denial_count"] > 0
assert any(
    item["status"] == 429
    and item.get("response", {}).get("error", {}).get("type") == "concurrency_limit"
    and item.get("response", {}).get("error", {}).get("code") == "tenant_concurrency_exceeded"
    for item in payload["responses"]
)
print(f"B_WITH_A_BLOCKED=1 success={payload['success_count']} denied={payload['denial_count']} required={required}")
PY
cp -a /work/construction/b_with_a "$RESULT_ROOT/evidence/phases/b_with_a"
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after_b.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_b.txt"
snapshot_metrics "$RESULT_ROOT/evidence/metrics_after_contested_b.json"

step=release_a_requests
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
a_started=0
drained=0
for _ in $(seq 1 120); do
  if python3 - "$A_HOST" "$A_PORT" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
a_active = sum(count for owner, count in metrics["active_by_owner"].items() if owner.startswith("embedding-drift-"))
raise SystemExit(0 if a_active == 0 else 1)
PY
  then
    drained=1
    break
  fi
  sleep 0.05
done
[ "$drained" = 1 ]
bash "$ROOT/platform/status_gateway.sh" >"$RESULT_ROOT/evidence/status_gateway_after_a_release.txt" 2>&1

step=b_unchanged_after_release
run_probe /work/construction/b_after_release/results.json "$B_RUN_ID-release" release \
  >"$RESULT_ROOT/evidence/b_after_release.stdout" 2>"$RESULT_ROOT/evidence/b_after_release.stderr"
python3 - /work/construction/b_alone/results.json /work/construction/b_with_a/results.json /work/construction/b_after_release/results.json "$B_REQUIRED_CONCURRENCY" <<'PY' >"$RESULT_ROOT/evidence/b_after_release_check.txt"
import json
import pathlib
import sys
alone, contested, released = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:4]]
required = int(sys.argv[4])
assert released["all_success"] is True
assert released["success_count"] == required and released["denial_count"] == 0
assert released["correct_count"] == required and released["aggregate_accuracy"] == 1.0
assert released["measured_peak_concurrency"] >= required
assert alone["gateway_identity"] == contested["gateway_identity"] == released["gateway_identity"]
assert alone["model"] == contested["model"] == released["model"]
assert alone["required_concurrency"] == contested["required_concurrency"] == released["required_concurrency"] == required
assert [item["case_id"] for item in alone["responses"]] == [item["case_id"] for item in released["responses"]]
print(f"RELEASE_RETRY_OK=1 success={released['success_count']} peak={released['measured_peak_concurrency']} required={required} gateway_identity_retained=1")
PY
cp -a /work/construction/b_after_release "$RESULT_ROOT/evidence/phases/b_after_release"
snapshot_metrics "$RESULT_ROOT/evidence/metrics_after_release_b.json"

step=stop_gateway
bash "$ROOT/platform/stop_gateway.sh" >"$RESULT_ROOT/evidence/stop_gateway.txt" 2>&1
gateway_started=0

step=complete
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_REQUIRED_CONCURRENCY=4 B_WITH_A_BLOCKED=1 CONCURRENCY_429=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 GATEWAY_OCCUPANCY=4 GATEWAY_IDENTITY_RETAINED=1 RELEASE_RETRY_OK=1 RESOURCE=api_concurrency REASON=continuously_replenished_batch_hard_capacity"
