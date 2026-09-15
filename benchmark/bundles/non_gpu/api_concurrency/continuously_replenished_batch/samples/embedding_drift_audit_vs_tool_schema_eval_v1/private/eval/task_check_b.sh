#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

output=$(python3 - "$B_OUTPUT_ROOT/results.json" "$ROOT/data/$B_CASE_FILE" "$MODEL_ID" "$B_OWNER" "$B_REQUIRED_CONCURRENCY" "$A_HOST" "$A_PORT" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import urllib.request

output_path, cases_path, model, owner, required, host, port = sys.argv[1:]
required = int(required)
payload = json.loads(pathlib.Path(output_path).read_text())
cases = json.loads(pathlib.Path(cases_path).read_text())
expected = {item["id"]: item["expected"] for item in cases}
responses = payload.get("responses", [])
by_id = {item.get("case_id"): item for item in responses}
run_id = payload.get("run_id")
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
key = f"{owner}/{run_id}"
labels_ok = set(by_id) == set(expected) and all(
    by_id[case_id].get("label") == label for case_id, label in expected.items()
)
responses_ok = all(
    item.get("status") == 200
    and item.get("model") == model
    and isinstance(item.get("confidence"), (int, float))
    for item in responses
)
api_ok = (
    metrics.get("peak_active_by_key", {}).get(key, 0) >= required
    and metrics.get("completed_by_key", {}).get(key, 0) >= len(cases)
)
content_ok = (
    payload.get("complete") is True
    and payload.get("model") == model
    and payload.get("owner") == owner
    and run_id == "tool-schema-migration"
    and payload.get("required_concurrency") == required
    and payload.get("successful_requests") == len(cases)
    and len(responses) == len(cases)
    and payload.get("aggregate_accuracy") == 1.0
    and labels_ok
    and responses_ok
    and api_ok
)
print(
    f"TASK_OK={int(content_ok)} COMPLETE={int(content_ok)} MODEL={payload.get('model')} "
    f"REQUIRED_CONCURRENCY={payload.get('required_concurrency')} RESPONSES={len(responses)} "
    f"LABELS_OK={int(labels_ok)} API_PEAK_OK={int(api_ok)}"
)
raise SystemExit(0 if content_ok else 1)
PY
)
rc=$?
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
if [ "$rc" -ne 0 ] && ! grep -q '^TASK_OK=' <<<"$output"; then
    echo "TASK_OK=0 reason=tool_schema_evaluation_contract_not_met"
fi
exit "$rc"
