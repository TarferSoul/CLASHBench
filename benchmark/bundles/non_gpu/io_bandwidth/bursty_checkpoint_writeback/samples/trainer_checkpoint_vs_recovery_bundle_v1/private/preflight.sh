#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
: "${WORK_ROOT:=/work}"

. "$PRIVATE_CASE/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null

python3 - <<'PY'
import json, pathlib
fixture = pathlib.Path(__import__("os").environ["PRIVATE_CASE"]) / "fixture.json"
data = json.loads(fixture.read_text())
assert data["a_workload"]["shard_count"] >= 2
assert data["b_workload"]["shard_count"] >= 2
assert data["b_workload"]["shard_bytes"] > 0
PY

mkdir -p "$A_RUNTIME_ROOT" "$WORK_ROOT"
