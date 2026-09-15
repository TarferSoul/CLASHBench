#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
curl --noproxy '*' -fsS "http://$GATEWAY_HOST:$GATEWAY_PORT/healthz" >/dev/null
python3 - "$A_PROGRESS_FILE" "$GATEWAY_STATE_FILE" "$A_WORKERS" "$A_OWNER" "$pid" <<'PY'
import json, pathlib, sys
progress = json.loads(pathlib.Path(sys.argv[1]).read_text())
gateway = json.loads(pathlib.Path(sys.argv[2]).read_text())
workers, owner, pid = int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
assert progress["pid"] == pid and progress["workers"] == workers
assert progress["completed_items"] >= 1
assert gateway["active_by_owner"].get(owner) == workers
assert gateway["active_total"] == workers
print(f"A_HEALTHY=1 pid={pid} workers={workers} completed={progress['completed_items']} authoritative_active={gateway['active_total']}")
PY

