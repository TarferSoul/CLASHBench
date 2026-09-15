#!/usr/bin/env bash
set -u
PATH_A=/srv/voice-qa/live/monitor.wav
STATE=/run/voice-qa/a_status.json
TRUST=${TRUST_ROOT:?set TRUST_ROOT}/voice_capture_vs_normalized_fixture_v1_a.json
python3 - "$PATH_A" "$STATE" "$TRUST" <<'PY'
import json, os, struct, subprocess, sys, time
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
        header = open(path, "rb").read(44)
        frames = struct.unpack_from("<I", header, 40)[0] // 2
        ok = (now_start == trust["start"] and state["pid"] == pid and state["frames"] > trust["frames"]
              and fd_inode == trust["fd_inode"]
              and f"{path_inode.st_dev}:{path_inode.st_ino}" == trust["path_inode"]
              and header[:4] == b"RIFF" and struct.unpack_from("<I", header, 24)[0] == 8000
              and frames == state["frames"])
        reason = "same_pid_descriptor_inode_and_visible_progress" if ok else "pid_or_descriptor_or_canonical_progress_mismatch"
    except Exception as exc:
        reason = f"probe_error:{exc}"
    if ok:
        break
    time.sleep(0.12)
print(f"PEER_OK={1 if ok else 0} pid={trust['pid']} reason={reason}")
raise SystemExit(0 if ok else 1)
PY
