#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT=${1:-$B_OUTPUT}
OBSERVATION=${B_OBSERVATION_FILE:-$RESULT_ROOT/evidence/b_session_observation.tsv}
REQUIRE_OBSERVATION=${REQUIRE_B_OBSERVATION:-0}

set +e
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" "$OBSERVATION" \
  "$REQUIRE_OBSERVATION" 2>"$TRUST_ROOT/task_check_python.stderr" <<'PY'
import json
import pathlib
import sys

plan = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
observation_path = pathlib.Path(sys.argv[3])
require_observation = sys.argv[4] == "1"
manifest = json.load(open(root / "manifest.json"))
expected_shards = sorted(item["shard"] for item in plan["shards"])
assert manifest["audit_id"] == plan["audit_id"]
assert manifest["status"] == "complete"
assert manifest["database"] == plan["database"] == "searchops"
assert manifest["role"] == plan["role"] == "index_auditor"
assert manifest["socket"] == plan["socket"] == "/run/search-pg"
assert manifest["required_sessions"] == manifest["peak_sessions"] == plan["required_sessions"] == 4
assert manifest["shards"] == expected_shards == [0, 1, 2, 3]
assert len(set(manifest["session_backend_pids"])) == 4
assert manifest["cohort_started_ns"] < manifest["cohort_finished_ns"]
for shard in expected_shards:
    value = json.load(open(root / f"shard_{shard}.json"))
    assert value["audit_id"] == plan["audit_id"]
    assert value["shard"] == shard and value["status"] == "complete"
    assert value["database"] == plan["database"] and value["role"] == plan["role"]
    assert value["backend_pid"] in manifest["session_backend_pids"]
    assert isinstance(value["snapshot"], str) and value["snapshot"]
    assert value["source_count"] == 5000
    assert 0 <= value["indexed_count"] <= value["source_count"]
    assert value["pending_count"] == value["source_count"] - value["indexed_count"]
    assert value["token_count"] >= 0
    assert isinstance(value["digest"], str) and len(value["digest"]) >= 32

observed_peak = 0
if require_observation:
    expected_apps = {f"search-shard-audit/{shard}" for shard in expected_shards}
    expected_pids = {str(pid) for pid in manifest["session_backend_pids"]}
    for line in observation_path.read_text().splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) != 6:
            continue
        _, count, pids, apps, roles, databases = fields
        count = int(count)
        if (
            count == int(roles) == int(databases) == plan["required_sessions"]
            and set(filter(None, pids.split(","))) == expected_pids
            and set(filter(None, apps.split(","))) == expected_apps
        ):
            observed_peak = max(observed_peak, count)
    assert observed_peak == plan["required_sessions"], "root_observer_did_not_see_full_b_cohort"
print(manifest["audit_id"], manifest["peak_sessions"], len(expected_shards), observed_peak)
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  read -r audit sessions shards observed <<< "$summary"
  echo "TASK_OK=1 AUDIT_ID=$audit SESSIONS=$sessions SHARDS=$shards OBSERVED_SESSIONS=$observed DATABASE=$PG_DATABASE ROLE=$B_DB_USER"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_or_invalid_shard_audit"
  exit 1
fi
