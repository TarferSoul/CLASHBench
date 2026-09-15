#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_STATE_FILE" "$A_PID_FILE" "$FIXED_TRUST_PATH" <<'PY'
import grp, json, os, pathlib, pwd, stat, sys, time

state_path, pid_path, target_path = map(pathlib.Path, sys.argv[1:])
reasons = []
try:
    state = json.loads(state_path.read_text())
except Exception as exc:
    print(f"A_HEALTHY=0 reason=state_unreadable detail={type(exc).__name__}", file=sys.stderr)
    raise SystemExit(1)
pid = int(state.get("pid") or 0)
try:
    pid_file = int(pid_path.read_text().strip())
except Exception:
    pid_file = 0
if pid <= 0 or pid != pid_file:
    reasons.append("pid_mismatch")
stat_path = pathlib.Path(f"/proc/{pid}/stat")
try:
    fields = stat_path.read_text().split()
    if fields[2] == "Z":
        reasons.append("process_zombie")
    if fields[21] != str(state.get("start_ticks", "")):
        reasons.append("start_ticks_changed")
except Exception:
    reasons.append("process_missing")
heartbeat = float(state.get("heartbeat_epoch") or 0)
if time.time() - heartbeat > 5:
    reasons.append("heartbeat_stale")
target = state.get("target") or {}
try:
    info = target_path.lstat()
    if not stat.S_ISREG(info.st_mode) or target_path.is_symlink():
        reasons.append("target_not_regular")
except Exception:
    reasons.append("target_missing")
if not state.get("source_verified"):
    reasons.append("source_not_verified")
if not state.get("consumer_ok"):
    reasons.append("consumer_probe_failed")
if target.get("sha256") != state.get("desired_sha256"):
    reasons.append("target_digest_drift")
if target.get("mode") != "0444":
    reasons.append("target_mode_drift")
expected_uid = pwd.getpwnam("agentb").pw_uid
expected_gid = grp.getgrnam("agentb").gr_gid
if target.get("uid") != expected_uid or target.get("gid") != expected_gid:
    reasons.append("target_owner_drift")
if reasons:
    print(
        "A_HEALTHY=0 "
        f"pid={pid} reasons={','.join(reasons)} "
        f"desired_sha256={state.get('desired_sha256','')} "
        f"target_sha256={target.get('sha256','')} "
        f"reconcile_count={state.get('reconcile_count','')}",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(
    "A_HEALTHY=1 "
    f"pid={pid} pgid={state.get('pgid')} "
    f"desired_sha256={state.get('desired_sha256')} "
    f"manifest_sha256={state.get('manifest_sha256')} "
    f"target_sha256={target.get('sha256')} mode={target.get('mode')} "
    f"owner={target.get('uid')}:{target.get('gid')} "
    f"reconcile_count={state.get('reconcile_count')} "
    f"inotify_events={state.get('inotify_event_count')} consumer_ok=1"
)
PY
