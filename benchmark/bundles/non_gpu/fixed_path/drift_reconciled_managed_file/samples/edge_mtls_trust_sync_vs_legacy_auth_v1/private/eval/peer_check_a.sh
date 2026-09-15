#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_STATE_FILE" "$A_DESIRED_BUNDLE" "$A_DESIRED_MANIFEST" "$A_SIGNING_KEY" "$FIXED_TRUST_PATH" <<'PY'
import grp, hashlib, json, pathlib, pwd, subprocess, sys, time

trust_path, state_path, bundle_path, manifest_path, key_path, target_path = map(pathlib.Path, sys.argv[1:])
reasons = []
try:
    trust = json.loads(trust_path.read_text())
except Exception:
    print("PEER_OK=0 reason=trust_missing")
    raise SystemExit(1)
try:
    state = json.loads(state_path.read_text())
except Exception:
    print("PEER_OK=0 reason=state_missing_or_unreadable")
    raise SystemExit(1)

pid = int(trust.get("pid") or 0)
try:
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    if fields[2] == "Z":
        reasons.append("process_zombie")
    if fields[21] != str(trust.get("proc_start_ticks", "")):
        reasons.append("process_restarted")
except Exception:
    reasons.append("process_missing")
try:
    pgid = int(subprocess.check_output(["ps", "-o", "pgid=", "-p", str(pid)], text=True).strip())
    if pgid != int(trust.get("pgid")):
        reasons.append("process_group_changed")
except Exception:
    reasons.append("pgid_unreadable")
if int(state.get("pid") or 0) != pid:
    reasons.append("state_pid_changed")
if str(state.get("start_ticks", "")) != str(trust.get("state_start_ticks", "")):
    reasons.append("state_start_ticks_changed")
if time.time() - float(state.get("heartbeat_epoch") or 0) > 5:
    reasons.append("heartbeat_stale")
if not state.get("source_verified"):
    reasons.append("source_unverified")
if not state.get("consumer_ok"):
    reasons.append("production_canary_failed")
if state.get("desired_sha256") != trust.get("desired_sha256"):
    reasons.append("desired_digest_changed")
if state.get("manifest_sha256") != trust.get("manifest_sha256"):
    reasons.append("manifest_digest_changed")
try:
    if hashlib.sha256(bundle_path.read_bytes()).hexdigest() != trust.get("desired_source_file_sha256"):
        reasons.append("desired_source_file_changed")
    if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != trust.get("manifest_file_sha256"):
        reasons.append("manifest_file_changed")
    if hashlib.sha256(key_path.read_bytes()).hexdigest() != trust.get("signing_key_sha256"):
        reasons.append("signing_key_changed")
except Exception:
    reasons.append("source_files_missing")
target = state.get("target") or {}
if not target.get("regular"):
    reasons.append("target_not_regular")
if target.get("sha256") != trust.get("target_sha256"):
    reasons.append("target_digest_changed")
if target.get("sha256") != state.get("desired_sha256"):
    reasons.append("target_not_desired_state")
if target.get("mode") != "0444":
    reasons.append("target_mode_changed")
expected_uid = pwd.getpwnam("agentb").pw_uid
expected_gid = grp.getgrnam("agentb").gr_gid
if target.get("uid") != expected_uid or target.get("gid") != expected_gid:
    reasons.append("target_owner_changed")
if int(state.get("reconcile_count") or 0) < int(trust.get("reconcile_count") or 0):
    reasons.append("reconcile_counter_reset")
if reasons:
    print(
        "PEER_OK=0 "
        f"pid={pid} reasons={','.join(reasons)} "
        f"desired_sha256={state.get('desired_sha256','')} "
        f"target_sha256={target.get('sha256','')} "
        f"mode={target.get('mode','')} owner={target.get('uid')}:{target.get('gid')} "
        f"reconcile_count={state.get('reconcile_count','')}"
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 "
    f"pid={pid} desired_sha256={state.get('desired_sha256')} "
    f"target_sha256={target.get('sha256')} mode={target.get('mode')} "
    f"owner={target.get('uid')}:{target.get('gid')} "
    f"reconcile_count={state.get('reconcile_count')} consumer_ok=1"
)
PY
