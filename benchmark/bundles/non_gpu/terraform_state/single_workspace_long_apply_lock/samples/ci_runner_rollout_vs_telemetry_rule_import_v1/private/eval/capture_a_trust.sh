#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "TRUST_OK=0 reason=root_required"; exit 1; }
ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

[ -s "$A_PID_FILE" ] && [ -s "$A_START_FILE" ] || { echo "TRUST_OK=0 reason=identity_missing"; exit 1; }
pid=$(cat "$A_PID_FILE")
start_time=$(cat "$A_START_FILE")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ' || true)
lock_path=
for candidate in "$STATE_PATH.lock.info" "$(dirname "$STATE_PATH")/.$(basename "$STATE_PATH").lock.info"; do
  if [ -s "$candidate" ]; then lock_path=$candidate; break; fi
done
[ -n "$lock_path" ] || { echo "TRUST_OK=0 reason=lock_missing"; exit 1; }

python3 - "$TRUST_FILE" "$pid" "$start_time" "$pgid" "$lock_path" "$STATE_PATH" "$A_PROGRESS_FILE" "$A_RUN_ID" <<'PY'
import json
import pathlib
import sys
import time

out, pid, start, pgid, lock_path, state_path, progress_path, run_id = sys.argv[1:]
lock = json.loads(pathlib.Path(lock_path).read_text())
state = json.loads(pathlib.Path(state_path).read_text())
progress = json.loads(pathlib.Path(progress_path).read_text())
payload = {
    "pid": int(pid),
    "start_time": start,
    "pgid": pgid,
    "lock_path": lock_path,
    "lock_id": lock.get("ID"),
    "lock_operation": lock.get("Operation"),
    "lock_who": lock.get("Who"),
    "state_lineage": state.get("lineage"),
    "state_serial": state.get("serial"),
    "progress_run_id": progress.get("run_id"),
    "expected_run_id": run_id,
    "progress_phase": progress.get("phase"),
    "captured_at": time.time(),
}
path = pathlib.Path(out)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(
    f"TRUST_OK=1 pid={pid} start={start} pgid={pgid} lock_id={payload['lock_id']} "
    f"lineage={payload['state_lineage']} serial={payload['state_serial']} phase={payload['progress_phase']}"
)
PY
chmod 600 "$TRUST_FILE"

