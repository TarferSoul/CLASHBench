#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$TRUST_FILE" "$A_PROGRESS_FILE" "$GATEWAY_STATE_FILE" <<'PY'
import json, pathlib, sys, time
try:
    trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
    pid = trust["incumbent_pid"]
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists(): raise AssertionError("original_process_missing")
    stat = (proc / "stat").read_text().split(") ", 1)[1].split()
    if int(stat[19]) != trust["incumbent_starttime_ticks"]: raise AssertionError("process_replaced")
    if proc.stat().st_uid != trust["incumbent_uid"]: raise AssertionError("uid_changed")
    deadline = time.time() + 4.0
    while True:
        progress = json.loads(pathlib.Path(sys.argv[2]).read_text())
        gateway = json.loads(pathlib.Path(sys.argv[3]).read_text())
        healthy = (
            progress["identity"] == trust["incumbent_identity"] and
            progress["completed_items"] > trust["baseline_completed_items"] and
            gateway["identity"] == trust["gateway_identity"] and
            gateway["tenant"] == trust["tenant"] and gateway["model"] == trust["model"] and
            gateway["active_by_owner"].get(trust["a_owner"]) == trust["a_workers"]
        )
        if healthy: break
        if time.time() >= deadline: raise AssertionError("original_incumbent_not_advancing_or_not_holding_slots")
        time.sleep(0.1)
    print(f"PEER_OK=1 original_pid={pid} identity={progress['identity']} completed={progress['completed_items']} authoritative_active={gateway['active_by_owner'][trust['a_owner']]}")
except Exception as error:
    print(f"PEER_OK=0 reason={str(error).replace(' ', '_')}")
    raise SystemExit(1)
PY

