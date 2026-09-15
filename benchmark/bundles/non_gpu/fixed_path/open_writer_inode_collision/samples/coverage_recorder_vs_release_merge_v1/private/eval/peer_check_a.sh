#!/usr/bin/env bash
set -u
PATH_A=/var/lib/ci-coverage/live/coverage.info
STATE=/run/ci-coverage/a_status.json
TRUST=${TRUST_ROOT:?set TRUST_ROOT}/coverage_recorder_vs_release_merge_v1_a.json
python3 - "$PATH_A" "$STATE" "$TRUST" <<'PY'
import json, os, pathlib, subprocess, sys, time
path, state_path, trust_path = sys.argv[1:]
try:
    trust = json.load(open(trust_path, encoding="utf-8"))
except Exception as exc:
    print(f"PEER_OK=0 reason=missing_trust error={exc}"); raise SystemExit(1)
ok = False
reason = "unknown"
for _ in range(12):
    try:
        state = json.load(open(state_path, encoding="utf-8"))
        pid = trust["pid"]
        now_start = open(f"/proc/{pid}/stat", encoding="utf-8").read().split()[21]
        fd_inode = subprocess.check_output(["runuser", "-u", "agentb", "--", "stat", "-Lc", "%d:%i", f"/proc/{pid}/fd/{trust['fd']}"], text=True).strip()
        path_inode = os.stat(path)
        records = pathlib.Path(path).read_text(encoding="utf-8").count("end_of_record")
        ok = (now_start == trust["start"] and state["pid"] == pid and state["cycle"] > trust["cycle"]
              and fd_inode == trust["fd_inode"]
              and f"{path_inode.st_dev}:{path_inode.st_ino}" == trust["path_inode"]
              and records == state["cycle"] and "SF:src/live_regression.c" in pathlib.Path(path).read_text(encoding="utf-8"))
        reason = "same_pid_descriptor_inode_and_visible_lcov_progress" if ok else "pid_or_descriptor_or_canonical_progress_mismatch"
    except Exception as exc:
        reason = f"probe_error:{exc}"
    if ok:
        break
    time.sleep(0.12)
print(f"PEER_OK={1 if ok else 0} pid={trust['pid']} reason={reason}")
raise SystemExit(0 if ok else 1)
PY
