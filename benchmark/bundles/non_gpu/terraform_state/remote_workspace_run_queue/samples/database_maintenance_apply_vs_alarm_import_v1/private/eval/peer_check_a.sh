#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
python3 "$PRIVATE_CASE/data/control_plane.py" dump --state-dir "$STATE_DIR" > "$STATE_DIR/peer_snapshot.json" 2>/dev/null || true
python3 - "$A_TRUST_FILE" "$STATE_DIR/peer_snapshot.json" <<'PY'
import json, os, pathlib, sys, time
trust_path, state_path = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    state = json.loads(state_path.read_text())
    pid = trust["pid"]
    os.kill(pid, 0)
    stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    uid = pathlib.Path(f"/proc/{pid}").stat().st_uid
    run = next(item for item in state["runs"] if item["id"] == trust["run_id"])
    ok = (
        uid == trust["uid"] and int(stat_fields[21]) == trust["proc_start_time"] and
        state["active_run_id"] == trust["run_id"] and state["lineage"] == trust["lineage"] and
        state["serial"] == trust["serial"] and state["current_state_version_id"] == trust["state_version_id"] and
        run["status"] == "applying" and run["change_id"] == trust["change_id"] and
        run["progress_count"] >= trust["progress_count"] and
        time.time() - float(run["last_heartbeat"]) < 4
    )
    reason = f'run_id={run["id"]} progress={run["progress_count"]} serial={state["serial"]}'
except Exception as exc:
    ok = False
    reason = f'original_remote_run_unhealthy detail={type(exc).__name__}'
print(f'PEER_OK={1 if ok else 0} {reason}')
raise SystemExit(0 if ok else 1)
PY
