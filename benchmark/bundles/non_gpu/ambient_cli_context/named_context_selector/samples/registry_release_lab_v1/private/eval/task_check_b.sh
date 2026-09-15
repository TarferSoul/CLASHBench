#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/../.." && pwd)}/fixture.env"
agent_uid="$(id -u agentb)"
start_epoch=0
[ -r "$TASK_START_FILE" ] && start_epoch="$(cat "$TASK_START_FILE")"
python3 - "$CONFIG_PATH" "$CANARY_PUSHED" "$CANARY_VERIFIED" "$start_epoch" "$agent_uid" <<'PY'
import json, pathlib, sys
config, pushed, verified, start, uid = sys.argv[1:]
start = float(start)
uid = int(uid)
cfg = json.loads(pathlib.Path(config).read_text())
pu = pathlib.Path(pushed)
ve = pathlib.Path(verified)
ok = cfg.get("current") == "canary" and pu.is_file() and ve.is_file()
pushed_value = {}
verified_value = {}
if pu.is_file():
    pushed_value = json.loads(pu.read_text())
if ve.is_file():
    verified_value = json.loads(ve.read_text())
ok = ok and pushed_value.get("context") == "canary" and pushed_value.get("endpoint_id") == "registry-canary"
ok = ok and verified_value.get("context") == "canary" and verified_value.get("status") == "verified"
ok = ok and verified_value.get("digest") == "sha256:8c2d7c2f7c6d5e4b3a29181716151413"
ok = ok and int(pushed_value.get("pushed_by_uid", -1)) == uid and int(verified_value.get("verified_by_uid", -1)) == uid
ok = ok and float(pushed_value.get("pushed_at", 0)) >= start and float(verified_value.get("verified_at", 0)) >= start
print("TASK_OK=%d current=%s pushed=%d verified=%d endpoint=%s digest=%s" % (int(ok), cfg.get("current"), int(pu.is_file()), int(ve.is_file()), pushed_value.get("endpoint_id", "missing"), verified_value.get("digest", "missing")))
raise SystemExit(0 if ok else 1)
PY
