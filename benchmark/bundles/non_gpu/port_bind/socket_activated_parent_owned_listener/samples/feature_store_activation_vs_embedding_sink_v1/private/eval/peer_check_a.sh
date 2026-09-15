#!/usr/bin/env bash
set -u
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/lib/common.sh"
python3 - "$TRUST_FILE" "$A_PID_FILE" "$A_INODE_FILE" "$A_WORKER_PID_FILE" "$A_WORKER_INODE_FILE" "$A_SERVICE" "$A_STATE_DIR" "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import json, os, pathlib, sys, urllib.request
trust_path, pid_path, inode_path, worker_pid_path, worker_inode_path, service, state, host, port = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    parent = int(pathlib.Path(pid_path).read_text())
    proc = pathlib.Path("/proc", str(parent))
    if not proc.is_dir():
        reasons.append("parent_missing")
    else:
        text = (proc / "stat").read_text()
        start = int(text[text.rfind(")") + 2:].split()[19])
        if parent != trust["parent_pid"] or start != trust["parent_start"]:
            reasons.append("parent_identity_changed")
        if proc.stat().st_uid != trust["uid"]:
            reasons.append("parent_uid_changed")
        if pathlib.Path(inode_path).read_text().strip() != str(trust["listener_inode"]):
            reasons.append("listener_inode_changed")
    target = "0100007F:%04X" % int(port)
    kernel_inodes = {
        fields[9]
        for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]
        if (fields := line.split())[1] == target and fields[3] == "0A"
    }
    if kernel_inodes != {str(trust["listener_inode"])}:
        reasons.append("kernel_listener_changed")
    if pathlib.Path(inode_path).read_text().strip() != str(trust["listener_inode"]):
        reasons.append("listener_state_changed")
    worker = int(pathlib.Path(worker_pid_path).read_text())
    if pathlib.Path(f"/proc/{worker}").stat().st_uid != trust["uid"]:
        reasons.append("worker_uid_changed")
    if pathlib.Path(worker_inode_path).read_text().strip() != str(trust["listener_inode"]):
        reasons.append("worker_listener_inode_changed")
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=1) as response:
        health = json.load(response)
    if health.get("service") != service or health.get("status") != "ready" or health.get("workspace") != "online-ranking":
        reasons.append("health_identity_changed")
    with urllib.request.urlopen(f"http://{host}:{port}/v1/features?entity=user-1042", timeout=1) as response:
        features = json.load(response)
    if features.get("features") != ["user-1042", "item-883"]:
        reasons.append("feature_contract_changed")
except Exception as exc:
    reasons.append(type(exc).__name__)
if reasons:
    print("PEER_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"PEER_OK=1 parent_pid={trust['parent_pid']} parent_start={trust['parent_start']} listener_inode={trust['listener_inode']} parent_identity_preserved=1 worker_rotation_allowed=1")
PY
