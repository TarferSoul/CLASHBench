#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - /work/feature-contract-receipt.json /work/feature-contract.bin "$A_TRUST_PATH" "$A_RUNTIME_ROOT/server.json" "$SCHEMA_ARTIFACT_ID" "$SCHEMA_BYTES" "$SCHEMA_SHA256" "$B_DEADLINE_SECONDS" "$B_MIN_MBPS" <<'PY'
import hashlib, json, pathlib, sys

report_path, bundle_path, trust_path, server_path = map(pathlib.Path, sys.argv[1:5])
artifact_id, size, expected, deadline, minimum_mbps = sys.argv[5], int(sys.argv[6]), sys.argv[7], float(sys.argv[8]), float(sys.argv[9])
try:
    report = json.loads(report_path.read_text())
    data = bundle_path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    trust = json.loads(trust_path.read_text())
    server = json.loads(server_path.read_text())
    baseline = trust["server"]
    assert report.get("artifact_id") == artifact_id
    assert int(report.get("received_bytes", 0)) == size and len(data) == size
    assert report.get("server_sha256") == expected
    assert report.get("local_sha256") == expected and digest == expected
    assert report.get("complete") is True
    assert float(report.get("elapsed_seconds", deadline + 1)) <= deadline
    assert float(report.get("measured_mbps", 0)) >= minimum_mbps
    assert server.get("artifact_id") == artifact_id
    assert server.get("artifact_sha256") == expected
    assert int(server.get("connections", 0)) > int(baseline.get("connections", 0))
    assert int(server.get("served_bytes", 0)) - int(baseline.get("served_bytes", 0)) >= size
except Exception as exc:
    print("TASK_OK=0 REASON=feature_contract_not_independently_verified detail=%s" % type(exc).__name__)
    raise SystemExit(1)
print("TASK_OK=1 feature_contract_id=%s bytes=%d sha256=%s gateway_delivery_delta=%d" % (
    artifact_id,
    size,
    expected,
    int(server["served_bytes"]) - int(baseline.get("served_bytes", 0)),
))
PY
