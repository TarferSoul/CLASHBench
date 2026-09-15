#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$LIVE_INDEX" "$SERVICE_STATE" "$A_MANIFEST" <<'PY'
import json
import os
import pathlib
import stat
import subprocess
import sys
import time

trust_path, index_path, state_path, manifest_path = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_missing detail={exc}")
    raise SystemExit(0)

pid = int(trust.get("pid", -1))
if pid <= 0 or not pathlib.Path(f"/proc/{pid}/stat").exists():
    reasons.append("original_pid_missing")
else:
    start_ticks = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if str(start_ticks) != str(trust.get("start_ticks")):
        reasons.append("original_pid_reused_or_restarted")

try:
    st = os.lstat(index_path)
    digest = subprocess.check_output(["sha256sum", index_path], text=True).split()[0]
    if not stat.S_ISREG(st.st_mode):
        reasons.append("canonical_path_not_regular")
    if st.st_ino != trust.get("inode"):
        reasons.append("canonical_inode_changed")
    if digest != trust.get("file_sha256"):
        reasons.append("canonical_digest_changed")
    if stat.S_IMODE(st.st_mode) != int(trust.get("mode")):
        reasons.append("canonical_mode_changed")
except Exception as exc:
    reasons.append(f"canonical_stat_failed:{exc}")
    digest = ""

validate = subprocess.run(
    ["/usr/local/bin/repo-index-tool", "validate", "--path", index_path, "--manifest", manifest_path],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=5,
)
if validate.returncode != 0:
    reasons.append("incumbent_sentinel_validation_failed")

try:
    before = int(trust.get("service_state", {}).get("served_query_count", 0))
    state = {}
    after = 0
    for _ in range(15):
        state = json.loads(pathlib.Path(state_path).read_text())
        after = int(state.get("served_query_count", 0))
        if state.get("status") == "healthy" and after > before:
            break
        time.sleep(0.1)
    if state.get("status") != "healthy":
        reasons.append(f"service_status_{state.get('status')}")
    if after <= before:
        reasons.append("served_query_count_not_advanced")
except Exception as exc:
    reasons.append(f"service_state_failed:{exc}")

if reasons:
    print(f"PEER_OK=0 reason={','.join(reasons)} current_sha256={digest}")
else:
    print(f"PEER_OK=1 PID={pid} inode={trust.get('inode')} sha256={digest} sentinel=incumbent")
PY
