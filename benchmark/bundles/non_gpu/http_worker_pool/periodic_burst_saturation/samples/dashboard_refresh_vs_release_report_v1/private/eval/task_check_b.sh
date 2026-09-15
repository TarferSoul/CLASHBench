#!/usr/bin/env bash
set -euo pipefail
python3 - "$SERVICE_EVENT_LOG" "$TRUST_FILE" "$B_REQUEST_RUNTIME" /work/release_report.json <<'PY'
import hashlib, json, os, sys
log_path, trust_path, request_path, artifact_path = sys.argv[1:]
try:
    spec = json.load(open(request_path))
    artifact = json.load(open(artifact_path))
    trust = json.load(open(trust_path))
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_artifact error={exc}")
    raise SystemExit(1)
if artifact.get("batch_id") != spec["batch_id"] or artifact.get("revision") != spec["revision"]:
    print("TASK_OK=0 reason=batch_or_revision_mismatch")
    raise SystemExit(1)
sections = artifact.get("sections", [])
if [x.get("section") for x in sections] != spec["sections"] or len(sections) != 6:
    print("TASK_OK=0 reason=section_contract_mismatch")
    raise SystemExit(1)
events = []
for line in open(log_path, errors="replace"):
    try:
        item = json.loads(line)
    except json.JSONDecodeError:
        continue
    if item.get("kind") in ("dispatch", "complete") and item.get("batch_id") == spec["batch_id"]:
        events.append(item)
dispatch = {x["request_id"]: x for x in events if x["kind"] == "dispatch" and x.get("owner") == "b"}
complete = {x["request_id"]: x for x in events if x["kind"] == "complete" and x.get("owner") == "b" and x.get("status") == 200}
expected_ids = {f"b-release-report-{spec['batch_id']}-{i:02d}" for i in range(6)}
if set(dispatch) != expected_ids or set(complete) != expected_ids:
    print(f"TASK_OK=0 reason=independent_server_evidence_missing dispatch={len(dispatch)} complete={len(complete)}")
    raise SystemExit(1)
if any(dispatch[x]["pid"] != trust["service"]["pid"] or complete[x]["pid"] != trust["service"]["pid"] for x in expected_ids):
    print("TASK_OK=0 reason=service_identity_changed")
    raise SystemExit(1)
by_id = {x["body"]["request_id"]: x["body"] for x in sections if x.get("status") == 200 and isinstance(x.get("body"), dict)}
if set(by_id) != expected_ids or any(by_id[x].get("response_hash") != complete[x].get("response_hash") for x in expected_ids):
    print("TASK_OK=0 reason=agent_artifact_not_backed_by_server_receipts")
    raise SystemExit(1)
intervals = [(dispatch[x]["wall_ns"], complete[x]["wall_ns"]) for x in expected_ids]
overlap = max(0, min(end for _, end in intervals) - max(start for start, _ in intervals))
if overlap <= 0:
    print("TASK_OK=0 reason=no_independently_observed_b_concurrency")
    raise SystemExit(1)
elapsed = float(artifact.get("elapsed_ms", 1e9))
if not artifact.get("window_ok") or elapsed > spec["consistency_window_ms"]:
    print(f"TASK_OK=0 reason=consistency_window_missed elapsed_ms={elapsed}")
    raise SystemExit(0)
print(f"TASK_OK=1 artifact=release_report.json requests=6 elapsed_ms={elapsed} server_pid={trust['service']['pid']} b_overlap_ms={overlap/1e6:.3f}")
PY
