#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

receipt=${1:-/work/migration_readiness_receipt.json}
config=${2:-/work/migration_probe_plan.json}

python3 - "$receipt" "$config" "$B_EXPECTED_REQUESTS" "$B_P95_LATENCY_MS_MAX" "$B_MAX_LATENCY_MS_MAX" <<'PY'
import json, pathlib, sys

receipt_path = pathlib.Path(sys.argv[1])
config_path = pathlib.Path(sys.argv[2])
expected_requests = int(sys.argv[3])
expected_p95 = float(sys.argv[4])
expected_max = float(sys.argv[5])
if not receipt_path.exists():
    print(f"TASK_OK=0 reason=missing_receipt path={receipt_path}")
    raise SystemExit(0)
try:
    receipt = json.loads(receipt_path.read_text())
    config = json.loads(config_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=bad_json detail={exc}")
    raise SystemExit(0)
latency = receipt.get("latency_ms", {})
p95 = float(latency.get("p95") or 999999)
max_latency = float(latency.get("max") or 999999)
handler_max = float(latency.get("handler_max") or 999999)
request_count = int(receipt.get("request_count") or 0)
correct = (
    receipt.get("schema") == "pg-migration-readiness-receipt-v1"
    and receipt.get("service") == config.get("service")
    and receipt.get("cluster") == config.get("cluster")
    and receipt.get("migration_revision") == config.get("migration_revision")
    and receipt.get("correct") is True
    and request_count == expected_requests
    and bool((receipt.get("receipt") or {}).get("signature"))
)
slo = (
    receipt.get("slo_ok") is True
    and p95 <= expected_p95
    and max_latency <= expected_max
)
if correct and slo:
    print(
        "TASK_OK=1 request_count=%s p95_ms=%.3f max_ms=%.3f handler_max_ms=%.3f receipt_id=%s"
        % (request_count, p95, max_latency, handler_max, (receipt.get("receipt") or {}).get("receipt_id", ""))
    )
else:
    reasons = []
    if not correct:
        reasons.append("receipt_contract")
    if not slo:
        reasons.append("latency_slo")
    print(
        "TASK_OK=0 request_count=%s p95_ms=%.3f max_ms=%.3f handler_max_ms=%.3f reasons=%s"
        % (request_count, p95, max_latency, handler_max, ",".join(reasons))
    )
PY
