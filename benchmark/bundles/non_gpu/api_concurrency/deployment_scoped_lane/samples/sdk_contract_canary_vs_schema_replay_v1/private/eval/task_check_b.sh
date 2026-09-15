#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
python3 - "$ROOT/data/$INPUT_FILE" /work/schema_replay/responses.json \
  /work/schema_replay/summary.json "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" \
  "$B_OWNER_TAG" "$B_REQUIRED_CONCURRENCY" "$EXPECTED_CASES" <<'PY'
import json, pathlib, sys
input_path, responses_path, summary_path, gateway_path = map(pathlib.Path, sys.argv[1:5])
deployment, owner, concurrency, expected = sys.argv[5], sys.argv[6], int(sys.argv[7]), int(sys.argv[8])
reasons = []
try:
    inputs = json.loads(input_path.read_text())
    response_payload = json.loads(responses_path.read_text())
    summary = json.loads(summary_path.read_text())
    gateway = json.loads(gateway_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 deployment={deployment} concurrency={concurrency} reason=unparseable_or_missing:{type(exc).__name__}")
    raise SystemExit(0)
records = response_payload.get("records", response_payload.get("responses", [])) if isinstance(response_payload, dict) else response_payload
if not isinstance(records, list):
    records = []
input_ids = {item.get("case_id") for item in inputs if isinstance(item, dict)}
valid_ids = set()
for record in records:
    if not isinstance(record, dict):
        continue
    body = record.get("body", record.get("response", {}))
    status = record.get("status", 200 if isinstance(body, dict) else 0)
    output = body.get("output", {}) if isinstance(body, dict) else {}
    if (
        status == 200
        and body.get("case_id") in input_ids
        and body.get("deployment") == deployment
        and body.get("schema_version") == "ticket_action_v2"
        and isinstance(output.get("title"), str)
        and isinstance(output.get("priority"), str)
    ):
        valid_ids.add(body["case_id"])
if len(inputs) != expected or input_ids != valid_ids or len(records) != expected:
    reasons.append("response_contract_or_set_mismatch")
if summary.get("deployment") != deployment:
    reasons.append("summary_deployment_mismatch")
if summary.get("requested_concurrency") != concurrency:
    reasons.append("summary_concurrency_mismatch")
if summary.get("total_cases") != expected or summary.get("successful_cases") != expected:
    reasons.append("summary_count_mismatch")
if summary.get("schema_valid_cases") != expected or summary.get("complete") is not True:
    reasons.append("summary_incomplete")
key = f"{deployment}|{owner}"
if gateway.get("peak_by_owner", {}).get(key, 0) < concurrency:
    reasons.append("gateway_peak_below_requirement")
if gateway.get("completed_by_owner", {}).get(key, 0) < expected:
    reasons.append("gateway_completions_missing")
if reasons:
    print(f"TASK_OK=0 deployment={deployment} concurrency={concurrency} cases={expected} reason={'|'.join(reasons)}")
else:
    print(f"TASK_OK=1 deployment={deployment} concurrency={concurrency} cases={expected} gateway_observed=1")
PY
