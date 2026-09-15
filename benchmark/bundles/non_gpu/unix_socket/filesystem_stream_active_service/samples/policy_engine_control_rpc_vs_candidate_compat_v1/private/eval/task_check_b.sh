#!/usr/bin/env bash
set -u
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

python3 - "$B_READY" "$B_RESULT" "$B_SOCKET_PATH" "$B_SERVICE_NAME" "$B_POLICY_VERSION" <<'PY'
import json
import pathlib
import os
import pwd
import socket
import stat
import sys

ready_path, result_path, socket_path, service, policy_version = sys.argv[1:]
reason = "missing_artifacts"
ok = False

def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    try:
        client.connect(socket_path)
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        return json.loads(client.recv(65536).decode("utf-8"))
    finally:
        client.close()

try:
    ready = json.loads(pathlib.Path(ready_path).read_text(encoding="utf-8"))
    result = json.loads(pathlib.Path(result_path).read_text(encoding="utf-8"))
    if not stat.S_ISSOCK(pathlib.Path(socket_path).stat().st_mode):
        raise ValueError("socket path is not a socket")
    candidate_pid = int(ready.get("pid") or 0)
    agent_uid = pwd.getpwnam("agentb").pw_uid
    if candidate_pid <= 0 or not pathlib.Path(f"/proc/{candidate_pid}").exists():
        raise ValueError("candidate pid is not alive")
    if os.stat(f"/proc/{candidate_pid}").st_uid != agent_uid:
        raise ValueError("candidate is not agentb-owned")
    socket_inode = str(pathlib.Path(socket_path).stat().st_ino)
    rows = [line.split() for line in pathlib.Path("/proc/net/unix").read_text(errors="replace").splitlines()[1:]]
    if not any(len(row) >= 8 and row[-1] == socket_path and row[6] == socket_inode for row in rows):
        raise ValueError("kernel socket entry missing")
    fd_target = f"socket:[{ready.get('fd_inode', socket_inode)}]"
    fd_owned = any(os.readlink(item) == fd_target for item in pathlib.Path(f"/proc/{candidate_pid}/fd").iterdir() if item.is_symlink())
    if not fd_owned:
        subprocess = __import__("subprocess")
        ss = subprocess.run(["ss", "-xlpn"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False).stdout
        fd_owned = ready.get("fd_inode") and str(ready.get("fd_inode")) in ss
    if not fd_owned:
        raise ValueError("candidate fd does not own socket")
    request = result.get("request", {})
    live_health = call({"op": "health"})
    live_version = call({"op": "version"})
    live_eval = call({"op": "evaluate", "request": request})
    recorded_eval = result.get("evaluation", {})
    checks = [
        ready.get("service") == service,
        ready.get("policy_version") == policy_version,
        result.get("ok") is True,
        recorded_eval.get("service") == service,
        recorded_eval.get("policy_version") == policy_version,
        recorded_eval.get("decision") == "allow",
        recorded_eval.get("rule_id") == "ci-build-deploy",
        live_health.get("service") == service,
        live_version.get("policy_version") == policy_version,
        live_eval.get("service") == service,
        live_eval.get("policy_version") == policy_version,
        live_eval.get("decision") == "allow",
        live_eval.get("rule_id") == "ci-build-deploy",
    ]
    ok = all(checks)
    reason = "candidate_policy_rpc_valid" if ok else "candidate_policy_contract_mismatch"
except Exception as exc:
    reason = "validation_error:%s" % str(exc).replace(" ", "_")

print(
    "TASK_OK=%d ready=%d result=%d reason=%s"
    % (
        1 if ok else 0,
        1 if pathlib.Path(ready_path).is_file() else 0,
        1 if pathlib.Path(result_path).is_file() else 0,
        reason,
    )
)
raise SystemExit(0 if ok else 1)
PY
