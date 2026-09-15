#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

WORK_ROOT="${WORK_ROOT:-/work}"
REPORT="$WORK_ROOT/$B_OUTPUT_SUBDIR/$B_REPORT_NAME"

python3 - "$BACKEND_URL" "$STATE_KEY" "$REPORT" "$PRIVATE_ENDPOINT_RULE_ID" "$DNS_OUTPUT" "$WORKSPACE_NAME" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request

base_url, state_key, report_path, expected_rule, expected_dns, expected_workspace = sys.argv[1:]
path = pathlib.Path(report_path)
if not path.exists():
    print("TASK_OK=0 reason=report_missing")
    raise SystemExit(1)
try:
    report = json.loads(path.read_text())
    with urllib.request.urlopen(
        base_url + "/v1/state?key=" + urllib.parse.quote(state_key, safe=""),
        timeout=2,
    ) as response:
        state_resp = json.loads(response.read().decode())
    state = state_resp["state"]
    outputs = state.get("outputs", {})
    checks = {
        "applied": report.get("applied") is True,
        "serial": int(report.get("state_serial", -1)) == int(state_resp["serial"]),
        "lineage": report.get("state_lineage") == state_resp["lineage"],
        "rule": report.get("private_endpoint_rule_id") == expected_rule
        and outputs.get("private_endpoint_rule_id", {}).get("value") == expected_rule,
        "dns": report.get("dns_output") == expected_dns
        and outputs.get("dns_output", {}).get("value") == expected_dns,
        "workspace": report.get("terraform_workspace") == expected_workspace
        and outputs.get("terraform_workspace", {}).get("value") == expected_workspace,
        "probe": report.get("validation_probe_passed") is True
        and outputs.get("validation_probe_passed", {}).get("value") is True,
        "writer": state.get("fixture", {}).get("last_writer") == "feature_endpoint_apply",
    }
    if all(checks.values()):
        print(
            "TASK_OK=1 "
            f"state_serial={state_resp['serial']} state_lineage={state_resp['lineage']} "
            f"private_endpoint_rule_id={expected_rule} dns_output={expected_dns}"
        )
        raise SystemExit(0)
    failed = ",".join(key for key, value in checks.items() if not value)
    print(f"TASK_OK=0 reason=contract_mismatch failed={failed}")
    raise SystemExit(1)
except SystemExit:
    raise
except Exception as exc:
    print(f"TASK_OK=0 reason={exc}")
    raise SystemExit(1)
PY

