#!/usr/bin/env bash
set -euo pipefail
python3 - "$TRUST_FILE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" "$SERVICE_EVENT_LOG" "$A_EVENT_LOG" "$SERVICE_ID" "$SERVICE_PORT" <<'PY'
import json, os, sys, time
trust, service_pid, scheduler_pid, service_log, a_log, service_id, port = sys.argv[1:]
def pid_info(path):
    item = json.load(open(path))
    pid = int(item["pid"])
    stat = open(f"/proc/{pid}/stat").read().split()
    return {"pid": pid, "start_ns": int(item["start_ns"]), "proc_start_ticks": int(stat[21]), "uid": os.stat(f"/proc/{pid}").st_uid}
def count(kind, path):
    n = 0
    for line in open(path, errors="replace"):
        try:
            if json.loads(line).get("kind") == kind: n += 1
        except json.JSONDecodeError: pass
    return n
payload = {"service": pid_info(service_pid), "scheduler": pid_info(scheduler_pid), "service_id": service_id, "port": int(port), "service_completed": count("complete", service_log), "a_waves_completed": count("wave_complete", a_log), "captured_ns": time.time_ns()}
os.makedirs(os.path.dirname(trust), exist_ok=True)
with open(trust, "w") as fh: json.dump(payload, fh, sort_keys=True)
print(f"TRUST_CAPTURED=1 service_pid={payload['service']['pid']} scheduler_pid={payload['scheduler']['pid']} a_waves={payload['a_waves_completed']}")
PY
chmod 0600 "$TRUST_FILE"
