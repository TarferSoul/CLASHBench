#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/fixture.env"

test -x "$CLI"
test -f "$REDIS_SERVER"
test -f "$B_REQUEST_FILE"
test -f "$PWD/data/catalog_segments.json" || test -f "$(dirname "$0")/data/catalog_segments.json"
"$CLI" broker-admin --broker-socket "$BROKER_SOCKET" ping >/dev/null
python3 - "$B_REQUEST_FILE" "$(dirname "$0")/fixture.json" "$(dirname "$0")/data/catalog_segments.json" <<'PY'
import json, pathlib, sys
for item in sys.argv[1:]:
    json.loads(pathlib.Path(item).read_text())
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
fixture = json.loads(pathlib.Path(sys.argv[2]).read_text())
segments = json.loads(pathlib.Path(sys.argv[3]).read_text())
assert request["requested_generation"] == fixture["hotfix_generation"]
assert sum(len(s["docs"]) for s in segments["segments"]) >= fixture["expected_min_docs"]
assert len(request["validation_queries"]) == fixture["expected_validation_queries"]
PY
echo "PREFLIGHT_OK redis_broker=1 request=1 fixture=1"
