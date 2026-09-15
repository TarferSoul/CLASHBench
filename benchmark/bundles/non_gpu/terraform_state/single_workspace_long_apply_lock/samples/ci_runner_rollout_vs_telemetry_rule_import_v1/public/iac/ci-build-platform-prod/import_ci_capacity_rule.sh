#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export TF_IN_AUTOMATION=1
terraform init -input=false -no-color
terraform validate -no-color
terraform apply -auto-approve -input=false -refresh=false -lock-timeout=6s -no-color
state_json=$(mktemp)
terraform state pull > "$state_json"
address=$(terraform output -raw ci_capacity_telemetry_rule_address)
runbook=$(terraform output -raw ci_capacity_runbook)
threshold=$(terraform output -raw ci_queue_threshold)
python3 - "$state_json" /work/ci_telemetry_import_report.json "$address" "$runbook" "$threshold" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
report_path, address, runbook, threshold = sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
resources = {f'{item.get("type")}.{item.get("name")}': item for item in state.get("resources", [])}
if address not in resources: raise SystemExit(f"missing expected state address: {address}")
instance = resources[address].get("instances", [{}])[0]
def find_identity(value):
    if isinstance(value, dict):
        if value.get("name") == "ci-runner-queue-depth" and value.get("metric") == "ci_runner_queue_depth":
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
report = {"imported_address": address, "rule_name": values.get("name"), "metric": values.get("metric"), "threshold": threshold, "runbook_url": runbook, "state_lineage": state.get("lineage"), "state_serial": state.get("serial")}
pathlib.Path(report_path).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, indent=2, sort_keys=True))
PY
