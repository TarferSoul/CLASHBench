#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$FIXED_POLICY_PATH" "$A_AUDIT_INTERVAL" "$BASELINE_RULE_COUNT" <<'PY'
import json, os, pathlib, pwd, grp, stat, sys, time
pid_file, state_file, target_path, interval, expected_rules = sys.argv[1:]
interval = float(interval)
expected_rules = int(expected_rules)
pid = int(pathlib.Path(pid_file).read_text().strip())
try:
    os.kill(pid, 0)
except OSError:
    raise SystemExit(f"A_HEALTHY=0 reason=pid_not_running pid={pid}")
state = json.loads(pathlib.Path(state_file).read_text())
if state.get("pid") != pid:
    raise SystemExit("A_HEALTHY=0 reason=state_pid_mismatch")
if time.time() - float(state.get("heartbeat", 0)) > interval + 3:
    raise SystemExit("A_HEALTHY=0 reason=heartbeat_stale")
target = pathlib.Path(target_path)
info = target.lstat()
mode = f"{stat.S_IMODE(info.st_mode):04o}"
uid = pwd.getpwnam("agentb").pw_uid
gid = grp.getgrnam("secscan").gr_gid
if not stat.S_ISREG(info.st_mode) or target.is_symlink():
    raise SystemExit("A_HEALTHY=0 reason=target_not_regular")
if mode != "0440" or info.st_uid != uid or info.st_gid != gid:
    raise SystemExit(f"A_HEALTHY=0 reason=metadata_drift mode={mode} uid={info.st_uid} gid={info.st_gid}")
if not state.get("source_verified"):
    raise SystemExit("A_HEALTHY=0 reason=source_not_verified")
if not state.get("canary_ok"):
    raise SystemExit("A_HEALTHY=0 reason=canary_failed")
if int(state.get("baseline_rule_count", 0)) != expected_rules:
    raise SystemExit("A_HEALTHY=0 reason=rule_count_mismatch")
print(
    "A_HEALTHY=1 "
    f"pid={pid} digest={state.get('target', {}).get('sha256', '')} "
    f"repairs={state.get('repair_count', 0)} audits={state.get('audit_count', 0)} "
    f"mode={mode} canary_ok=1"
)
PY
