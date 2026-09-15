#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

bash "$ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$SHARED_CONFIG" "$A_HEARTBEAT_FILE" "$A_TRUST_FILE" "$A_WORKER_PATH" <<'PY'
import hashlib, json, os, pathlib, sys, time
pid_file, state_file, config_file, heartbeat_file, trust_file, worker_file = sys.argv[1:]
pid_data = json.load(open(pid_file, encoding="utf-8"))
state = json.load(open(state_file, encoding="utf-8"))
session = json.load(open(config_file, encoding="utf-8"))
pid = int(pid_data["pid"])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
uid_line = next(line for line in status if line.startswith("Uid:"))
trust = {
    "captured_at": time.time(),
    "pid": pid,
    "process_start_ticks": int(stat[21]),
    "process_group": int(stat[4]),
    "process_uid": int(uid_line.split()[1]),
    "service_instance_id": state["service_instance_id"],
    "lease_id": state["lease_id"],
    "session_epoch": int(state["session_epoch"]),
    "config_generation": state["config_generation"],
    "effective_principal": state["effective_principal"],
    "effective_organization": state["effective_organization"],
    "effective_channel": state["effective_channel"],
    "verified_package": state["verified_package"],
    "verified_digest": state["verified_digest"],
    "managed_by": session["managed_by"],
    "heartbeat_count": sum(1 for line in open(heartbeat_file, encoding="utf-8") if line.strip()),
    "worker_sha256": hashlib.sha256(pathlib.Path(worker_file).read_bytes()).hexdigest(),
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
print(f"A_TRUST_CAPTURED=1 pid={pid} start_ticks={trust['process_start_ticks']} uid={trust['process_uid']} instance={trust['service_instance_id']} lease_id={trust['lease_id']} session_epoch={trust['session_epoch']} generation={trust['config_generation']} principal={trust['effective_principal']} organization={trust['effective_organization']} channel={trust['effective_channel']} verified={trust['verified_package']}")
PY
