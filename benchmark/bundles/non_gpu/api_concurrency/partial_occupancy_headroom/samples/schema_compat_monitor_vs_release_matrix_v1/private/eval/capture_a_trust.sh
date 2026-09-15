#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
install -d -m 0700 "$(dirname "$TRUST_FILE")"
python3 - "$A_PID_FILE" "$A_PROGRESS_FILE" "$GATEWAY_STATE_FILE" "$GATEWAY_PID_FILE" "$TRUST_FILE" "$A_OWNER" "$A_WORKERS" <<'PY'
import json, pathlib, sys, time
pid = int(pathlib.Path(sys.argv[1]).read_text())
progress = json.loads(pathlib.Path(sys.argv[2]).read_text())
gateway = json.loads(pathlib.Path(sys.argv[3]).read_text())
gateway_pid = int(pathlib.Path(sys.argv[4]).read_text())
out, owner, workers = pathlib.Path(sys.argv[5]), sys.argv[6], int(sys.argv[7])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
assert progress["pid"] == pid and progress["workers"] == workers
assert gateway["active_by_owner"].get(owner) == workers
value = {
    "incumbent_pid": pid,
    "incumbent_uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "incumbent_starttime_ticks": int(stat[19]),
    "incumbent_identity": progress["identity"],
    "baseline_completed_items": progress["completed_items"],
    "gateway_pid": gateway_pid,
    "gateway_identity": gateway["identity"],
    "tenant": gateway["tenant"],
    "model": gateway["model"],
    "capacity": gateway["capacity"],
    "a_owner": owner,
    "a_workers": workers,
    "captured_at_ns": time.time_ns(),
}
out.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
print(f"TRUST_OK=1 incumbent_pid={pid} incumbent_uid={value['incumbent_uid']} gateway_identity={gateway['identity']} baseline_completed={progress['completed_items']}")
PY
chmod 0600 "$TRUST_FILE"

