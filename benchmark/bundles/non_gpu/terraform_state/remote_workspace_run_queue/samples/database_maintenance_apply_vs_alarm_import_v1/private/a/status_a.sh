#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
pid=$(cat "$A_RUNTIME/executor.pid")
run_id=$(cat "$A_RUNTIME/run.id")
kill -0 "$pid"
[ "$(stat -c %U "/proc/$pid")" = agentb ]
python3 "$PRIVATE_CASE/data/control_plane.py" dump --state-dir "$STATE_DIR" > "$STATE_DIR/status_probe.json"
python3 - "$STATE_DIR/status_probe.json" "$run_id" "$A_CHANGE_ID" "$BASE_SERIAL" <<'PY'
import json, sys, time
state = json.load(open(sys.argv[1]))
run_id, change_id, base_serial = sys.argv[2], sys.argv[3], int(sys.argv[4])
run = next(item for item in state["runs"] if item["id"] == run_id)
ok = (
    state["active_run_id"] == run_id and state["serial"] == base_serial and
    run["change_id"] == change_id and run["kind"] == "incumbent" and
    run["status"] == "applying" and run["progress_count"] >= 2 and
    time.time() - float(run["last_heartbeat"]) < 3
)
if not ok:
    raise SystemExit(1)
print(f'A_HEALTHY=1 run_id={run_id} progress_count={run["progress_count"]} serial={state["serial"]}')
PY
