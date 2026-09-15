#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$B_REPORT" "$PRODUCTION_LINK" "$CANDIDATE_TARGET" "$SERVICE_HOST" "$SERVICE_PORT" "$EXPECTED_CANDIDATE_MODEL" "$EXPECTED_CANDIDATE_CALIBRATION" "$EXPECTED_TOP_ORDER" <<'PY'
import json, os, pathlib, sys, urllib.request
report, link, candidate, host, port, expected_model, expected_cal, expected_order = sys.argv[1:]
expected = expected_order.split(",")
reasons = []
data = {}
try:
    data = json.loads(pathlib.Path(report).read_text())
except Exception as exc:
    reasons.append(f"report_missing_or_invalid:{exc}")
raw = os.readlink(link) if os.path.islink(link) else ""
if raw != candidate:
    reasons.append(f"alias_not_candidate:{raw}")
try:
    req = urllib.request.Request(
        f"http://{host}:{port}/rerank",
        data=json.dumps({
            "query": "neural reranking latency calibration",
            "documents": [
                {"id": "doc-1", "text": "baseline dense retrieval reranker with neural calibration notes"},
                {"id": "doc-2", "text": "sparse lexical filter fallback for recall accounting"},
                {"id": "doc-3", "text": "int8 reranking candidate lowers latency while preserving calibration"}
            ]
        }).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    api = json.loads(urllib.request.urlopen(req, timeout=1.5).read().decode())
except Exception as exc:
    api = {}
    reasons.append(f"api_probe_failed:{exc}")

report_order = data.get("ordered_document_ids") or data.get("top_document_order")
if data.get("model_id") != expected_model:
    reasons.append(f"report_model:{data.get('model_id')}")
if data.get("calibration_id") != expected_cal:
    reasons.append(f"report_calibration:{data.get('calibration_id')}")
if list(report_order or []) != expected:
    reasons.append(f"report_order:{report_order}")
if data.get("passed") is not True:
    reasons.append("report_passed_not_true")
if api.get("model_id") != expected_model:
    reasons.append(f"api_model:{api.get('model_id')}")
if api.get("calibration_id") != expected_cal:
    reasons.append(f"api_calibration:{api.get('calibration_id')}")
if list(api.get("ordered_document_ids") or []) != expected:
    reasons.append(f"api_order:{api.get('ordered_document_ids')}")

if reasons:
    print(f"TASK_OK=0 reasons={';'.join(reasons)}")
    raise SystemExit(1)
print(f"TASK_OK=1 model_id={expected_model} calibration_id={expected_cal} order={','.join(expected)} target={raw}")
PY
