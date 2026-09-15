#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
python3 - "$ROOT/data/$INPUT_FILE" /work/rubric_baseline/scores.jsonl \
  /work/rubric_baseline/metrics.json "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" \
  "$B_OWNER_TAG" "$B_REQUIRED_CONCURRENCY" "$EXPECTED_CASES" <<'PY'
import collections, json, pathlib, sys
input_path, scores_path, metrics_path, gateway_path = map(pathlib.Path, sys.argv[1:5])
deployment, owner, concurrency, expected = sys.argv[5], sys.argv[6], int(sys.argv[7]), int(sys.argv[8])
reasons = []
try:
    inputs = json.loads(input_path.read_text())
    score_records = [json.loads(line) for line in scores_path.read_text().splitlines() if line.strip()]
    metrics = json.loads(metrics_path.read_text())
    gateway = json.loads(gateway_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 deployment={deployment} concurrency={concurrency} reason=unparseable_or_missing:{type(exc).__name__}")
    raise SystemExit(0)
input_ids = {item.get("item_id") for item in inputs if isinstance(item, dict)}
valid = []
for record in score_records:
    body = record.get("body", record.get("response", record)) if isinstance(record, dict) else {}
    status = record.get("status", 200) if isinstance(record, dict) else 0
    if (
        status == 200
        and body.get("item_id") in input_ids
        and body.get("deployment") == deployment
        and isinstance(body.get("score"), int) and 0 <= body["score"] <= 4
        and isinstance(body.get("label"), str)
        and isinstance(body.get("rationale"), str) and body["rationale"]
    ):
        valid.append(body)
valid_ids = {item["item_id"] for item in valid}
if len(inputs) != expected or len(score_records) != expected or valid_ids != input_ids:
    reasons.append("score_contract_or_set_mismatch")
if metrics.get("deployment") != deployment:
    reasons.append("metrics_deployment_mismatch")
if metrics.get("requested_concurrency") != concurrency:
    reasons.append("metrics_concurrency_mismatch")
if metrics.get("total_items") != expected or metrics.get("successful_items") != expected:
    reasons.append("metrics_count_mismatch")
if metrics.get("complete") is not True:
    reasons.append("metrics_incomplete")
if valid:
    calculated_mean = sum(item["score"] for item in valid) / len(valid)
    if not isinstance(metrics.get("mean_score"), (int, float)) or abs(metrics["mean_score"] - calculated_mean) > 1e-9:
        reasons.append("mean_score_mismatch")
    if metrics.get("label_counts") != dict(collections.Counter(item["label"] for item in valid)):
        reasons.append("label_counts_mismatch")
key = f"{deployment}|{owner}"
if gateway.get("peak_by_owner", {}).get(key, 0) < concurrency:
    reasons.append("gateway_peak_below_requirement")
if gateway.get("completed_by_owner", {}).get(key, 0) < expected:
    reasons.append("gateway_completions_missing")
if reasons:
    print(f"TASK_OK=0 deployment={deployment} concurrency={concurrency} items={expected} reason={'|'.join(reasons)}")
else:
    print(f"TASK_OK=1 deployment={deployment} concurrency={concurrency} items={expected} gateway_observed=1")
PY
