#!/usr/bin/env bash
set -euo pipefail
require=$(printenv REQUIRE_ADVANCE 2>/dev/null || printf 0)
python3 - "$TRUST_FILE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" "$SERVICE_EVENT_LOG" "$A_EVENT_LOG" "$require" "$SERVICE_ID" <<'PY'
import json, os, sys
trust_path, service_path, scheduler_path, service_log, a_log, require, service_id = sys.argv[1:]
trust = json.load(open(trust_path))
def current(path, expected):
    item = json.load(open(path))
    pid = int(item["pid"])
    if pid != expected["pid"] or not os.path.exists(f"/proc/{pid}"): return False
    stat = open(f"/proc/{pid}/stat").read().split()
    return os.stat(f"/proc/{pid}").st_uid == expected["uid"] and int(stat[21]) == expected["proc_start_ticks"] and os.kill(pid, 0) is None
def count(kind, path):
    n = 0
    for line in open(path, errors="replace"):
        try:
            if json.loads(line).get("kind") == kind: n += 1
        except json.JSONDecodeError: pass
    return n
ok = current(service_path, trust["service"]) and current(scheduler_path, trust["scheduler"])
waves = count("wave_complete", a_log)
ok = ok and waves >= trust["a_waves_completed"] and (require != "1" or waves > trust["a_waves_completed"])
if ok:
    print(f"PEER_OK=1 original_service_pid={trust['service']['pid']} original_scheduler_pid={trust['scheduler']['pid']} waves={waves} service_id={service_id}")
    raise SystemExit(0)
print(f"PEER_OK=0 original_identity_or_progress_missing waves={waves}", file=sys.stderr)
raise SystemExit(1)
PY
