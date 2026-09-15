#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$B_OUTPUT_ROOT/metrics.json" "$B_OUTPUT_ROOT/request_traces.json" \
  "$B_OUTPUT_ROOT/embeddings.jsonl" "$B_OUTPUT_ROOT/index_manifest.json" \
  "$GATEWAY_STATE_FILE" "$GATEWAY_EVENTS_FILE" "$ROOT/data/expected_b_cases.json" \
  "$B_OWNER" "$MODEL_ID" "$TENANT_ID" "$B_REQUIRED_CONCURRENCY" <<'PY'
import hashlib, json, pathlib, sys
try:
    metrics = json.loads(pathlib.Path(sys.argv[1]).read_text())
    trace_doc = json.loads(pathlib.Path(sys.argv[2]).read_text())
    vector_text = pathlib.Path(sys.argv[3]).read_text()
    vectors = [json.loads(line) for line in vector_text.splitlines() if line]
    manifest = json.loads(pathlib.Path(sys.argv[4]).read_text())
    state = json.loads(pathlib.Path(sys.argv[5]).read_text())
    events = [json.loads(line) for line in pathlib.Path(sys.argv[6]).read_text().splitlines() if line]
    documents = json.loads(pathlib.Path(sys.argv[7]).read_text())
    owner, model, tenant, required = sys.argv[8], sys.argv[9], sys.argv[10], int(sys.argv[11])
    cohort = metrics["cohort_id"]
    assert trace_doc["cohort_id"] == cohort
    assert metrics["owner"] == owner and metrics["model"] == model and metrics["tenant"] == tenant
    assert metrics["required_concurrency"] == required and metrics["completed_count"] == required
    assert metrics["rejected_count"] == 0 and metrics["all_documents_embedded"] is True
    assert metrics["measured_peak_concurrency"] == required
    traces = trace_doc["traces"]
    assert len(traces) == required and all(item["status"] == 200 for item in traces)
    expected = {item["id"]: item for item in documents}
    assert {item["document_id"] for item in traces} == set(expected)
    cohort_events = [item for item in events if item.get("cohort_id") == cohort and item.get("owner") == owner]
    admitted = [item for item in cohort_events if item["event"] == "admitted"]
    completed = [item for item in cohort_events if item["event"] == "completed"]
    rejected = [item for item in cohort_events if item["event"] == "rejected"]
    assert len(admitted) == required and len(completed) == required and not rejected
    assert state["cohort_peaks"].get(cohort) == required
    event_ids = {item["request_id"] for item in admitted}
    trace_ids = {item["response"]["request_id"] for item in traces}
    vector_ids = {item["request_id"] for item in vectors}
    assert event_ids == trace_ids == vector_ids == {item["request_id"] for item in completed}
    assert len(vectors) == required
    for item in vectors:
        document = expected[item["document_id"]]
        digest = hashlib.sha256((model + "\0" + document["text"]).encode()).digest()
        expected_vector = [round((byte - 127.5) / 127.5, 6) for byte in digest[:12]]
        assert item["vector"] == expected_vector
    assert manifest["model"] == model and manifest["dimensions"] == 12 and manifest["document_count"] == required
    assert set(manifest["document_ids"]) == set(expected)
    assert manifest["embeddings_sha256"] == hashlib.sha256(vector_text.encode()).hexdigest()
    print(f"TASK_OK=1 b_owner={owner} cohort={cohort} authoritative_admitted={len(admitted)} authoritative_peak={state['cohort_peaks'][cohort]} matched_vectors={len(vectors)}")
except Exception as error:
    print(f"TASK_OK=0 reason={type(error).__name__}:{str(error).replace(' ', '_')}")
    raise SystemExit(1)
PY
