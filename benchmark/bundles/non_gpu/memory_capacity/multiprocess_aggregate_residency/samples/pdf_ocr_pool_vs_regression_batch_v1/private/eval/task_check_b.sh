#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

out=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
python3 - "$out" "$B_CORPUS_MANIFEST" "$B_WORKER_COUNT" "$B_EXPECTED_PAGE_COUNT" "$B_EXPECTED_DOC_COUNT" <<'PY'
import csv
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
corpus = json.load(open(sys.argv[2]))
workers = int(sys.argv[3])
pages = int(sys.argv[4])
doc_count = int(sys.argv[5])
metrics_path = out / "metrics.json"
mismatches_path = out / "mismatches.csv"
reasons = []
if not metrics_path.exists():
    reasons.append("missing_metrics_json")
    metrics = {}
else:
    metrics = json.loads(metrics_path.read_text())
if not mismatches_path.exists():
    reasons.append("missing_mismatches_csv")
else:
    rows = list(csv.DictReader(mismatches_path.open()))
    if rows:
        reasons.append("mismatches_present")
if metrics.get("status") != "complete":
    reasons.append("status_not_complete")
if metrics.get("requested_workers") != workers:
    reasons.append("requested_worker_count_wrong")
if metrics.get("max_live_workers") != workers:
    reasons.append("max_live_worker_count_wrong")
if metrics.get("page_count") != pages:
    reasons.append("page_count_wrong")
if sorted(metrics.get("document_ids") or []) != sorted(corpus["document_ids"]):
    reasons.append("document_ids_wrong")
if len(metrics.get("document_ids") or []) != doc_count:
    reasons.append("document_count_wrong")
if metrics.get("feature_checksum") != corpus["expected_feature_checksum"]:
    reasons.append("feature_checksum_wrong")
if metrics.get("expected_feature_checksum") != corpus["expected_feature_checksum"]:
    reasons.append("expected_checksum_not_reported")

if reasons:
    print("TASK_OK=0 reason={} output={}".format(",".join(reasons), out))
    raise SystemExit(1)
print(
    "TASK_OK=1 workers={} pages={} documents={} checksum={}".format(
        workers,
        metrics.get("page_count"),
        len(metrics.get("document_ids") or []),
        metrics.get("feature_checksum"),
    )
)
PY

