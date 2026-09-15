#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

[ -s "$A_PID_FILE" ] || { echo "A_STATUS_OK=0 reason=missing_pid"; exit 1; }
pid=$(cat "$A_PID_FILE")
kill -0 "$pid" 2>/dev/null || { echo "A_STATUS_OK=0 reason=pid_not_alive pid=$pid"; exit 1; }
[ -S "$A_SOCKET_PATH" ] || { echo "A_STATUS_OK=0 reason=socket_missing"; exit 1; }
[ -s "$A_FD_INODE_FILE" ] || { echo "A_STATUS_OK=0 reason=fd_inode_missing"; exit 1; }
[ -s "$A_PATH_INODE_FILE" ] || { echo "A_STATUS_OK=0 reason=path_inode_missing"; exit 1; }

python3 - "$A_SOCKET_PATH" "$A_SERVICE_NAME" "$A_POLICY_VERSION" "$A_GENERATION_TOKEN" \
  "$A_FD_INODE_FILE" "$A_PATH_INODE_FILE" <<'PY'
import json
import os
import socket
import stat
import sys

socket_path, service, policy_version, generation, fd_file, path_file = sys.argv[1:]
fd_inode = open(fd_file, encoding="utf-8").read().strip()
path_inode = open(path_file, encoding="utf-8").read().strip()

def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    try:
        client.connect(socket_path)
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        return json.loads(client.recv(65536).decode("utf-8"))
    finally:
        client.close()

st = os.lstat(socket_path)
if not stat.S_ISSOCK(st.st_mode):
    raise SystemExit("path is not a socket")
if str(st.st_ino) != path_inode:
    raise SystemExit("path inode mismatch")
with open("/proc/net/unix", encoding="utf-8", errors="replace") as handle:
    rows = [line.split() for line in handle if line.split() and line.split()[-1] == socket_path]
if not any(len(row) >= 7 and row[6] == fd_inode for row in rows):
    raise SystemExit("fd inode absent from /proc/net/unix")
health = call({"op": "health"})
version = call({"op": "version"})
if not (
    health.get("ok") is True
    and health.get("service") == service
    and health.get("policy_version") == policy_version
    and health.get("generation_token") == generation
    and version.get("service") == service
    and version.get("policy_version") == policy_version
):
    raise SystemExit("policy service identity mismatch")
print(
    "A_STATUS_OK=1 pid_alive=1 service=%s policy_version=%s generation=%s eval_count=%s fd_inode=%s path_inode=%s"
    % (service, policy_version, generation, health.get("eval_count"), fd_inode, path_inode)
)
PY

