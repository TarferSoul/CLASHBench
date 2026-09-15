#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
PUBLIC_ROOT=${CASE_PUBLIC_ROOT:-/work}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
NODE_CHECK=
if command -v node >/dev/null 2>&1; then
  NODE_CHECK=node
elif [ -x /opt/node/bin/node ]; then
  NODE_CHECK=/opt/node/bin/node
fi

python3 -m py_compile \
  "$ROOT/platform/model_gateway.py" \
  "$ROOT/a/sdk_contract_matrix.py" \
  "$PUBLIC_ROOT/tools/node_compat_validate_structured.py"
if [ -n "$NODE_CHECK" ]; then
  "$NODE_CHECK" --check "$PUBLIC_ROOT/tools/validate-structured-output.mjs" >/dev/null
fi

python3 - "$ROOT/data/ci_contract_cases.jsonl" "$PUBLIC_ROOT/fixtures/structured_output_regressions.jsonl" "$ROOT/fixture.json" <<'PY'
import json
import pathlib
import sys

ci_cases_path, b_cases_path, fixture_path = map(pathlib.Path, sys.argv[1:])
ci_cases = [json.loads(line) for line in ci_cases_path.read_text().splitlines() if line.strip()]
b_cases = [json.loads(line) for line in b_cases_path.read_text().splitlines() if line.strip()]
fixture = json.loads(fixture_path.read_text())
assert len(ci_cases) >= 30
assert len(b_cases) == 8
assert fixture["profile_id"] == "distributed_worker_aggregation"
assert fixture["benchmark_track"] == "hard_capacity"
assert fixture["variant_id"] == "contract_ci_shards_vs_sdk_schema_check"
assert fixture["gateway"]["tenant"] == "sdk-release-ci"
assert fixture["gateway"]["deployment"] == "cb-chat-eval-2026-07"
assert fixture["gateway"]["capacity"] == 12
assert fixture["incumbent"]["shards"] == 5
assert sum(fixture["incumbent"]["shard_internal_concurrency"]) == 9
assert fixture["user_task"]["required_concurrency"] == 5
for item in ci_cases:
    assert item["id"] and item["area"] and item["name"] and item["request"] and item["assertions"]
for item in b_cases:
    assert item["id"] and item["schema_name"] and item["input"] and item["expected_fields"]
print(f"PREFLIGHT_OK=1 ci_cases={len(ci_cases)} structured_output_cases={len(b_cases)}")
PY
