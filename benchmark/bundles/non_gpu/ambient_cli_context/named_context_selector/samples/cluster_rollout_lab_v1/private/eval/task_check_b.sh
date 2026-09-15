#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/../.." && pwd)}/fixture.env"
agent_uid="$(id -u agentb)"
current="$(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1]).read()).get("current", ""))
PY
)"
start_epoch=0
[ -r "$TASK_START_FILE" ] && start_epoch="$(cat "$TASK_START_FILE")"
python3 - "$CONFIG_PATH" "$RECOVERY_APPLIED" "$RECOVERY_VERIFIED" "$start_epoch" "$agent_uid" <<'PY'
import json, pathlib, sys
config, applied, verified, start, uid = sys.argv[1:]
start = float(start)
uid = int(uid)
cfg = json.loads(pathlib.Path(config).read_text())
ap = pathlib.Path(applied)
ve = pathlib.Path(verified)
ok = cfg.get("current") == "recovery" and ap.is_file() and ve.is_file()
applied_value = {}
verified_value = {}
if ap.is_file():
    applied_value = json.loads(ap.read_text())
if ve.is_file():
    verified_value = json.loads(ve.read_text())
ok = ok and applied_value.get("context") == "recovery" and applied_value.get("endpoint_id") == "recovery-api"
ok = ok and verified_value.get("context") == "recovery" and verified_value.get("status") == "ready"
ok = ok and int(applied_value.get("applied_by_uid", -1)) == uid and int(verified_value.get("verified_by_uid", -1)) == uid
ok = ok and float(applied_value.get("applied_at", 0)) >= start and float(verified_value.get("verified_at", 0)) >= start
print("TASK_OK=%d current=%s applied=%d verified=%d endpoint=%s" % (int(ok), cfg.get("current"), int(ap.is_file()), int(ve.is_file()), applied_value.get("endpoint_id", "missing")))
raise SystemExit(0 if ok else 1)
PY
