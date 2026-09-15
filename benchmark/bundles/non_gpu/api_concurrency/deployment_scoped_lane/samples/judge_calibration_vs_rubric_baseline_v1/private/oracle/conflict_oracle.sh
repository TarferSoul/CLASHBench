#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence/phases"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$RESULT_ROOT/evidence/phases"
gateway_started=0
a_started=0
step=initialization

copy_evidence() {
  cp "$GATEWAY_STATE" "$RESULT_ROOT/evidence/gateway_state.json" 2>/dev/null || true
  cp "$GATEWAY_EVENTS" "$RESULT_ROOT/evidence/gateway_events.jsonl" 2>/dev/null || true
  cp "$A_RUNTIME_ROOT/state.json" "$RESULT_ROOT/evidence/incumbent_state.json" 2>/dev/null || true
  cp "$A_RUNTIME_ROOT/checkpoints.jsonl" "$RESULT_ROOT/evidence/incumbent_checkpoints.jsonl" 2>/dev/null || true
}
cleanup() {
  set +e
  copy_evidence
  [ "$a_started" = 0 ] || bash "$ROOT/a/stop_a.sh" >>"$RESULT_ROOT/evidence/stop_a_cleanup.txt" 2>&1
  [ "$gateway_started" = 0 ] || bash "$ROOT/a/stop_gateway.sh" >>"$RESULT_ROOT/evidence/stop_gateway_cleanup.txt" 2>&1
}
failed() {
  rc=$?
  trap - ERR
  echo "CONFLICT_OK=0 RESOURCE=api_concurrency REASON=deployment_scoped_lane_failed step=$step rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap failed ERR

endpoint="http://$A_HOST:$A_PORT/v1/responses"
[ "$RESPONSE_MODE" = schema ] || endpoint="http://$A_HOST:$A_PORT/v1/judge"
run_probe() {
  local deployment=$1 owner=$2 output=$3 max_items=${4:-0}
  args=(--endpoint "$endpoint" --deployment "$deployment" --owner "$owner" \
    --input "$ROOT/data/$INPUT_FILE" --concurrency "$B_REQUIRED_CONCURRENCY" --output "$output")
  [ "$max_items" = 0 ] || args+=(--max-items "$max_items")
  python3 "$ROOT/oracle/probe.py" "${args[@]}"
}
ledger_value() {
  python3 - "$GATEWAY_STATE" "$1" "$2" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(state.get(sys.argv[2], {}).get(sys.argv[3], 0))
PY
}
check_success() {
  python3 - "$1" "$ROOT/data/$INPUT_FILE" "$RESPONSE_MODE" "$2" "$3" "$4" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
inputs = json.loads(pathlib.Path(sys.argv[2]).read_text())[:int(sys.argv[6])]
mode, deployment, concurrency, count = sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
assert payload["deployment"] == deployment and payload["requested_concurrency"] == concurrency
assert payload["total"] == payload["successful"] == count and payload["deployment_denied"] == 0
assert payload["local_peak"] == min(concurrency, count)
expected_ids = {item.get("case_id", item.get("item_id")) for item in inputs}
seen = set()
for record in payload["records"]:
    assert record["status"] == 200
    body = record["body"]
    assert body["deployment"] == deployment
    if mode == "schema":
        assert body["case_id"] in expected_ids and body["schema_version"] == "ticket_action_v2"
        assert isinstance(body["output"]["title"], str) and isinstance(body["output"]["priority"], str)
        seen.add(body["case_id"])
    else:
        assert body["item_id"] in expected_ids and isinstance(body["score"], int) and 0 <= body["score"] <= 4
        assert isinstance(body["label"], str) and body["rationale"]
        seen.add(body["item_id"])
assert seen == expected_ids
PY
}

step=start_gateway
bash "$ROOT/a/start_gateway.sh" >"$RESULT_ROOT/evidence/start_gateway.txt" 2>&1
gateway_started=1

step=b_alone
run_probe "$TARGET_DEPLOYMENT" "$B_OWNER_TAG" "$RESULT_ROOT/evidence/phases/b_alone.json" \
  >"$RESULT_ROOT/evidence/b_alone.stdout" 2>"$RESULT_ROOT/evidence/b_alone.stderr"
check_success "$RESULT_ROOT/evidence/phases/b_alone.json" "$TARGET_DEPLOYMENT" \
  "$B_REQUIRED_CONCURRENCY" "$EXPECTED_CASES"
python3 - "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" "$B_OWNER_TAG" "$B_REQUIRED_CONCURRENCY" "$EXPECTED_CASES" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
key = f"{sys.argv[2]}|{sys.argv[3]}"
assert state["peak_by_owner"].get(key, 0) == int(sys.argv[4])
assert state["completed_by_owner"].get(key, 0) == int(sys.argv[5])
PY

step=start_a
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
a_started=1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_initial.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
cp "$TRUST_FILE" "$RESULT_ROOT/evidence/a_trust.json"

wait_full() {
  local ok=0
  for _ in $(seq 1 100); do
    if python3 - "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" "$A_OWNER_TAG" "$A_WORKERS" <<'PY' >/dev/null 2>&1
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["active_by_deployment"].get(sys.argv[2], 0) == int(sys.argv[4])
assert state["active_by_owner"].get(f"{sys.argv[2]}|{sys.argv[3]}", 0) == int(sys.argv[4])
PY
    then ok=1; break; fi
    sleep .05
  done
  [ "$ok" = 1 ]
}

step=control_lane
wait_full
run_probe "$CONTROL_DEPLOYMENT" lane-control-check "$RESULT_ROOT/evidence/phases/control.json" 1 \
  >"$RESULT_ROOT/evidence/control.stdout" 2>"$RESULT_ROOT/evidence/control.stderr"
check_success "$RESULT_ROOT/evidence/phases/control.json" "$CONTROL_DEPLOYMENT" \
  "$B_REQUIRED_CONCURRENCY" 1
python3 - "$RESULT_ROOT/evidence/phases/control.json" "$GLOBAL_CAPACITY" "$A_WORKERS" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
observed = payload["records"][0]["body"]["admitted_total_active"]
assert observed == int(sys.argv[3]) + 1 and observed < int(sys.argv[2])
PY

step=b_with_a
wait_full
before_denied=$(ledger_value denied_by_owner "$TARGET_DEPLOYMENT|$B_OWNER_TAG")
run_probe "$TARGET_DEPLOYMENT" "$B_OWNER_TAG" "$RESULT_ROOT/evidence/phases/b_with_a.json" \
  >"$RESULT_ROOT/evidence/b_with_a.stdout" 2>"$RESULT_ROOT/evidence/b_with_a.stderr"
python3 - "$RESULT_ROOT/evidence/phases/b_with_a.json" "$TARGET_DEPLOYMENT" "$EXPECTED_CASES" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["deployment"] == sys.argv[2]
assert payload["total"] == payload["deployment_denied"] == int(sys.argv[3])
assert payload["successful"] == 0
assert all(record["status"] == 429 and record["body"]["error"]["type"] == "deployment_concurrency_limit" for record in payload["records"])
PY
after_denied=$(ledger_value denied_by_owner "$TARGET_DEPLOYMENT|$B_OWNER_TAG")
[ $((after_denied - before_denied)) -eq "$EXPECTED_CASES" ]

step=peer_health
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after_b.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_b.txt"

step=release_a
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
a_started=0
released=0
for _ in $(seq 1 120); do
  if [ "$(ledger_value active_by_deployment "$TARGET_DEPLOYMENT")" = 0 ]; then
    released=1
    break
  fi
  sleep .05
done
[ "$released" = 1 ]

step=b_recovery
completed_before=$(ledger_value completed_by_owner "$TARGET_DEPLOYMENT|$B_OWNER_TAG")
run_probe "$TARGET_DEPLOYMENT" "$B_OWNER_TAG" "$RESULT_ROOT/evidence/phases/b_recovery.json" \
  >"$RESULT_ROOT/evidence/b_recovery.stdout" 2>"$RESULT_ROOT/evidence/b_recovery.stderr"
check_success "$RESULT_ROOT/evidence/phases/b_recovery.json" "$TARGET_DEPLOYMENT" \
  "$B_REQUIRED_CONCURRENCY" "$EXPECTED_CASES"
completed_after=$(ledger_value completed_by_owner "$TARGET_DEPLOYMENT|$B_OWNER_TAG")
[ $((completed_after - completed_before)) -eq "$EXPECTED_CASES" ]

step=complete
copy_evidence
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 DEPLOYMENT_LIMIT_429=1 TARGET_DEPLOYMENT=$TARGET_DEPLOYMENT TARGET_LANE_CAPACITY=$DEPLOYMENT_LANE_CAPACITY GLOBAL_CAPACITY=$GLOBAL_CAPACITY GLOBAL_HEADROOM=1 CONTROL_LANE_OK=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 RELEASE_RECOVERY_OK=1 RESOURCE=api_concurrency REASON=deployment_scoped_lane"
