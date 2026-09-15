#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

output=$(python3 - "$B_TRACE_DIR" "$B_REPORT" "$B_CASES" "$MODEL_ID" "$TENANT_ID" "$B_OWNER" "$B_RUN_ID" "$B_REQUIRED_CONCURRENCY" "$A_HOST" "$A_PORT" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import urllib.request

trace_dir, report_path, cases_path, deployment, tenant, owner, run_id, required, host, port = sys.argv[1:]
required = int(required)
trace_dir = pathlib.Path(trace_dir)
cases = [json.loads(line) for line in pathlib.Path(cases_path).read_text().splitlines() if line.strip()]
expected_ids = {item["id"] for item in cases}
report_file = pathlib.Path(report_path)
report = json.loads(report_file.read_text()) if report_file.exists() else {}
traces = []
if trace_dir.exists():
    for path in sorted(trace_dir.glob("*.json")):
        traces.append(json.loads(path.read_text()))
by_id = {item.get("case_id"): item for item in traces}
try:
    with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
        metrics = json.load(response)
except Exception:
    metrics = {}
key = f"{owner}/{run_id}"
rows_ok = (
    set(by_id) == expected_ids
    and all(
        row.get("deployment") == deployment
        and row.get("schema_valid") is True
        and row.get("schema_name")
        and row.get("response_hash")
        and row.get("response_id")
        and isinstance(row.get("normalized"), dict)
        for row in traces
    )
)
summary_ok = (
    report.get("deployment") == deployment
    and report.get("tenant") == tenant
    and report.get("owner") == owner
    and report.get("run_id") == run_id
    and report.get("total_fixtures") == len(cases)
    and report.get("completed_fixtures") == len(cases)
    and report.get("trace_count") == len(cases)
    and report.get("failed_fixture_ids") == []
    and report.get("required_concurrency") == required
    and int(report.get("observed_peak_concurrency", 0)) >= required
    and report.get("schema_pass_rate") == 1
    and report.get("complete") is True
)
api_peak = int(metrics.get("peak_active_by_key", {}).get(key, 0) or 0)
api_completed = int(metrics.get("completed_by_key", {}).get(key, 0) or 0)
api_ok = api_peak >= required and api_completed >= len(cases)
ok = rows_ok and summary_ok and api_ok
print(
    f"TASK_OK={int(ok)} COMPLETE={int(ok)} DEPLOYMENT={report.get('deployment')} "
    f"TRACES={len(traces)} TOTAL_FIXTURES={report.get('total_fixtures')} "
    f"SCHEMA_PASS_RATE={report.get('schema_pass_rate')} RETRIES={report.get('retry_count')} "
    f"REQUIRED_CONCURRENCY={report.get('required_concurrency')} OBSERVED_PEAK={report.get('observed_peak_concurrency')} "
    f"API_PEAK={api_peak} API_COMPLETED={api_completed} ROWS_OK={int(rows_ok)} SUMMARY_OK={int(summary_ok)} API_OK={int(api_ok)}"
)
raise SystemExit(0 if ok else 1)
PY
)
rc=$?
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
if [ "$rc" -ne 0 ] && ! grep -q '^TASK_OK=' <<<"$output"; then
  echo "TASK_OK=0 reason=structured_output_validation_contract_not_met"
fi
exit "$rc"
