#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
id "$A_SERVICE_USER" >/dev/null
test -x "$CLI_PATH"
python3 -m json.tool "$ROOT/data/a_partition_queue.json" >/dev/null
python3 -m json.tool "$ROOT/data/replay_partitions.json" >/dev/null
python3 - "$ROOT/fixture.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["canonical_pidfile"] == "/run/warehouse-snapshot/dispatcher.pid"
assert value["b_request_id"] == "warehouse-replay-2026-08-05"
PY
mkdir -p "$A_RUNTIME_DIR" "$A_STATE_DIR"
chown -R "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_DIR"
runuser -u "$A_SERVICE_USER" -- test -w "$A_RUNTIME_DIR"
