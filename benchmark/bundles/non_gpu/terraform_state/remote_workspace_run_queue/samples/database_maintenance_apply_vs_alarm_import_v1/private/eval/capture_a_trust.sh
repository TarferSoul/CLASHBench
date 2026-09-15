#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
pid=$(cat "$A_RUNTIME/executor.pid")
run_id=$(cat "$A_RUNTIME/run.id")
start_time=$(awk '{print $22}' "/proc/$pid/stat")
uid=$(stat -c %u "/proc/$pid")
python3 "$PRIVATE_CASE/data/control_plane.py" dump --state-dir "$STATE_DIR" > "$STATE_DIR/trust_snapshot.json"
python3 - "$STATE_DIR/trust_snapshot.json" "$A_TRUST_FILE" "$pid" "$uid" "$start_time" "$run_id" <<'PY'
import json, pathlib, sys, time
state_path, out, pid, uid, start_time, run_id = sys.argv[1:]
state = json.load(open(state_path))
run = next(item for item in state["runs"] if item["id"] == run_id)
payload = {
    "captured_at": time.time(), "pid": int(pid), "uid": int(uid),
    "proc_start_time": int(start_time), "run_id": run_id,
    "change_id": run["change_id"], "workspace_id": state["workspace_id"],
    "lineage": state["lineage"], "serial": state["serial"],
    "state_version_id": state["current_state_version_id"],
    "progress_count": run["progress_count"], "apply_started_seq": run["apply_started_seq"],
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$A_TRUST_FILE"
printf 'A_TRUST_CAPTURED=1 pid=%s run_id=%s\n' "$pid" "$run_id"
