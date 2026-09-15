#!/usr/bin/env bash
set -euo pipefail
ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$STATE_PATH" "$B_RESULT_FILE" "$B_TARGET" "$B_ALERT_NAME" "$B_RUNBOOK_URL" "$B_THRESHOLD_MS" "$ALERT_FIXTURE_PATH" <<'PY'
import json, pathlib, sys
state_path, report_path, address, rule_name, runbook, threshold, fixture_path = sys.argv[1:]
threshold = int(threshold)
def fail(reason):
    print(f"TASK_OK=0 reason={reason}"); raise SystemExit(0)
state_file, report_file, fixture_file = map(pathlib.Path, (state_path, report_path, fixture_path))
if not state_file.exists(): fail("state_missing")
if not report_file.exists(): fail("report_missing")
if not fixture_file.exists(): fail("telemetry_fixture_missing")
try:
    state = json.loads(state_file.read_text()); report = json.loads(report_file.read_text()); fixture = json.loads(fixture_file.read_text())
except Exception as exc:
    fail(f"json_invalid:{type(exc).__name__}")
resources = {f'{item.get("type")}.{item.get("name")}': item for item in state.get("resources", [])}
resource = resources.get(address)
if resource is None: fail("telemetry_state_missing")
if report.get("imported_address") != address: fail("report_address_mismatch")
if report.get("rule_name") != rule_name or report.get("metric") != fixture.get("metric"): fail("report_rule_identity_mismatch")
if report.get("runbook_url") != runbook: fail("report_runbook_mismatch")
if int(report.get("threshold", -1)) != threshold: fail("report_threshold_mismatch")
if report.get("state_lineage") != state.get("lineage"): fail("report_lineage_mismatch")
if report.get("state_serial") != state.get("serial"): fail("report_serial_mismatch")
instance = resource.get("instances", [{}])[0]
def find_identity(value):
    if isinstance(value, dict):
        if value.get("name") == fixture.get("name") and value.get("metric") == fixture.get("metric"):
            return value
        for child in value.values():
            found = find_identity(child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_identity(child)
            if found is not None:
                return found
    elif isinstance(value, str):
        try:
            return find_identity(json.loads(value))
        except (TypeError, json.JSONDecodeError):
            return None
    return None
values = find_identity(instance) or {}
if values.get("name") != fixture.get("name") or values.get("metric") != fixture.get("metric"): fail("state_metric_value_mismatch")
print(f"TASK_OK=1 resource={address} rule={rule_name} metric={fixture.get('metric')} threshold={threshold} serial={state.get('serial')} lineage={state.get('lineage')}")
PY
