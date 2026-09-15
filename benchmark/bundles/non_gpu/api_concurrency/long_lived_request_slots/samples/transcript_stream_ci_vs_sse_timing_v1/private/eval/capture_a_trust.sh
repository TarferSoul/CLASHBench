#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
pid=$(cat "$A_PID_FILE")
service_pid=$(cat "$SERVICE_PID")
python3 - "$SERVICE_STATE" "$TRUST_PATH" "$pid" "$service_pid" "$(id -u "${AGENT_USER:-agentb}")" <<'PY'
import json, pathlib, sys, time
state_path, trust_path, holder_pid, service_pid, expected_uid = sys.argv[1:]
holder_pid = int(holder_pid)
service_pid = int(service_pid)
state = json.loads(pathlib.Path(state_path).read_text())
ids = ["transcript-index-104", "transcript-index-219", "transcript-index-337"]
requests = {key: state["requests"][key] for key in ids}
assert all(value["active"] and value["owner"] == "transcript-indexer" for value in requests.values())
holder_uid = pathlib.Path(f"/proc/{holder_pid}").stat().st_uid
assert holder_uid == int(expected_uid) and holder_uid > 0
payload = {
    "holder_pid": holder_pid,
    "holder_uid": holder_uid,
    "holder_start_ticks": pathlib.Path(f"/proc/{holder_pid}/stat").read_text().split()[21],
    "service_pid": service_pid,
    "service_start_ticks": pathlib.Path(f"/proc/{service_pid}/stat").read_text().split()[21],
    "request_ids": ids,
    "event_counts": {key: requests[key]["events"] for key in ids},
    "captured_at": time.time(),
}
pathlib.Path(trust_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURED=1 holder_pid={holder_pid} holder_uid={holder_uid} requests={len(ids)}")
PY
chmod 600 "$TRUST_PATH"
