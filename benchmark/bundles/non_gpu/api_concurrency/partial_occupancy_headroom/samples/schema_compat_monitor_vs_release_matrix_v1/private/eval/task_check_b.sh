#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$B_OUTPUT_ROOT/release_matrix.json" "$B_OUTPUT_ROOT/response_traces.json" \
  "$GATEWAY_STATE_FILE" "$GATEWAY_EVENTS_FILE" "$ROOT/data/expected_b_cases.json" \
  "$B_OWNER" "$MODEL_ID" "$TENANT_ID" "$B_REQUIRED_CONCURRENCY" <<'PY'
import hashlib, json, pathlib, sys
try:
    report = json.loads(pathlib.Path(sys.argv[1]).read_text())
    trace_doc = json.loads(pathlib.Path(sys.argv[2]).read_text())
    state = json.loads(pathlib.Path(sys.argv[3]).read_text())
    events = [json.loads(line) for line in pathlib.Path(sys.argv[4]).read_text().splitlines() if line]
    cases = json.loads(pathlib.Path(sys.argv[5]).read_text())
    owner, model, tenant, required = sys.argv[6], sys.argv[7], sys.argv[8], int(sys.argv[9])
    cohort = report["cohort_id"]
    assert trace_doc["cohort_id"] == cohort
    assert report["owner"] == owner and report["model"] == model and report["tenant"] == tenant
    assert report["required_concurrency"] == required
    assert report["completed_count"] == required and report["rejected_count"] == 0
    assert report["all_cases_successful"] is True and report["measured_peak_concurrency"] == required
    traces = trace_doc["traces"]
    assert len(traces) == required and all(item["status"] == 200 for item in traces)
    expected = {item["id"]: item for item in cases}
    assert {item["case_id"] for item in traces} == set(expected)
    cohort_events = [item for item in events if item.get("cohort_id") == cohort and item.get("owner") == owner]
    admitted = [item for item in cohort_events if item["event"] == "admitted"]
    completed = [item for item in cohort_events if item["event"] == "completed"]
    rejected = [item for item in cohort_events if item["event"] == "rejected"]
    assert len(admitted) == required and len(completed) == required and not rejected
    assert state["cohort_peaks"].get(cohort) == required
    admitted_ids = {item["request_id"] for item in admitted}
    completed_ids = {item["request_id"] for item in completed}
    trace_ids = {item["response"]["request_id"] for item in traces}
    assert admitted_ids == completed_ids == trace_ids
    assert {item["case_id"] for item in admitted} == set(expected)
    for item in traces:
        case = expected[item["case_id"]]
        canonical = json.dumps(case, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256((canonical + model).encode()).hexdigest()
        assert item["response"]["schema_digest"] == digest and item["response"]["schema_valid"] is True
    print(f"TASK_OK=1 b_owner={owner} cohort={cohort} authoritative_admitted={len(admitted)} authoritative_peak={state['cohort_peaks'][cohort]} matched_request_ids={len(trace_ids)}")
except Exception as error:
    print(f"TASK_OK=0 reason={type(error).__name__}:{str(error).replace(' ', '_')}")
    raise SystemExit(1)
PY

