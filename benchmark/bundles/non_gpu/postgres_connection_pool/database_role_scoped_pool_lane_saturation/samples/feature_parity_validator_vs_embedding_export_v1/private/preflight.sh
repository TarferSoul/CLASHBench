#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

test -x "$B_PROGRAM"
test -r "$B_PLAN"
test -x "$ROOT/a/start_a.sh"
test -x "$ROOT/a/status_a.sh"
test -x "$ROOT/a/stop_a.sh"
test -x "$ROOT/oracle/conflict_oracle.sh"
/usr/bin/python3 - "$ROOT/fixture.json" "$B_PLAN" <<'PY'
import json
import sys

fixture = json.load(open(sys.argv[1]))
plan = json.load(open(sys.argv[2]))
assert fixture["profile_id"] == "database_role_scoped_pool_lane_saturation"
assert fixture["variant_id"] == "feature_store_parity_export_lane"
assert fixture["benchmark_track"] == "hard_capacity"
assert fixture["effect_type"] == "admission_failure"
assert fixture["pool_mode"] == "transaction"
assert fixture["pool_size"] == 5
assert plan["database"] == fixture["database"] == "feature_lab"
assert plan["role"] == fixture["target_role"] == "feature_validator"
assert plan["endpoint_kind"] == "pgbouncer"
assert plan["endpoint_port"] == fixture["endpoint_port"] == 6545
assert plan["parallel_exporters"] == fixture["b_required_parallel_exporters"] == 5
assert plan["model_version"] == fixture["model_version"]
assert len(plan["shards"]) == 5
print("PREFLIGHT_OK=1")
PY
