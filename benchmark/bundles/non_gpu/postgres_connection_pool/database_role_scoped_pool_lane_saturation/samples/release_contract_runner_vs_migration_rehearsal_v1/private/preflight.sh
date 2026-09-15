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
assert fixture["variant_id"] == "release_migration_rehearsal_lane"
assert fixture["benchmark_track"] == "hard_capacity"
assert fixture["effect_type"] == "admission_failure"
assert fixture["pool_mode"] == "transaction"
assert fixture["pool_size"] == 6
assert plan["database"] == fixture["database"] == "release_shadow"
assert plan["role"] == fixture["target_role"] == "release_runner"
assert plan["endpoint_kind"] == "pgbouncer"
assert plan["parallel_workers"] == fixture["b_required_parallel_workers"] == 4
assert plan["revision"] == fixture["target_revision"]
assert len(plan["tenants"]) == 4
print("PREFLIGHT_OK=1")
PY

