#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

if [ ! -r "$A_TRUST_FILE" ]; then
  echo "PEER_OK=0 reason=missing_trust"
  exit 1
fi

set +e
python3 - \
  "$A_TRUST_FILE" \
  "$A_SOCKET_PATH" \
  "$A_JOURNAL_FILE" \
  "$A_SERVICE_NAME" \
  "$A_API_VERSION" \
  "$B_FEATURE_KEY" <<'PY'
import json
import os
import pathlib
import socket
import stat
import sys

trust_path, socket_path, journal_path, service, api_version, feature_key = sys.argv[1:]
api_version = int(api_version)
trust = json.loads(pathlib.Path(trust_path).read_text())
manager_pid = int(trust["manager_pid"])
reason = []

def fail(name):
    reason.append(name)

try:
    current_start = pathlib.Path(f"/proc/{manager_pid}/stat").read_text().split()[21]
    if current_start != trust["manager_start_ticks"]:
        fail("manager_restarted")
except Exception:
    fail("manager_missing")

try:
    sock_stat = os.stat(socket_path)
    if not stat.S_ISSOCK(sock_stat.st_mode):
        fail("socket_path_not_socket")
    saved = trust["socket_path_stat"]
    if int(sock_stat.st_dev) != int(saved["device"]) or int(sock_stat.st_ino) != int(saved["inode"]):
        fail("socket_path_replaced")
except Exception:
    fail("socket_path_missing")

listener_inode = ""
try:
    for line in pathlib.Path("/proc/net/unix").read_text().splitlines()[1:]:
        parts = line.split()
        if parts and parts[-1] == socket_path:
            listener_inode = parts[6]
    if listener_inode != str(trust["listener_inode"]):
        fail("listener_inode_changed")
except Exception:
    fail("proc_unix_unreadable")

health_ok = False
describe_ok = False
try:
    def call(payload):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2.0)
        client.connect(socket_path)
        client.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
        client.close()
        return json.loads(data.split(b"\n", 1)[0].decode())
    health = call({"op": "health"})
    describe = call({"op": "describe", "feature": feature_key})
    health_ok = (
        health.get("ok") is True
        and health.get("service") == service
        and int(health.get("api_version")) == api_version
        and int(health.get("catalog_entries")) == 2
    )
    feature = describe.get("feature") or {}
    describe_ok = (
        describe.get("ok") is True
        and describe.get("service") == service
        and int(describe.get("api_version")) == api_version
        and feature.get("name") == feature_key
    )
except Exception:
    fail("activation_protocol_failed")

try:
    records = [json.loads(line) for line in pathlib.Path(journal_path).read_text().splitlines() if line]
except Exception:
    records = []
if not records:
    fail("journal_missing")

if reason or not health_ok or not describe_ok:
    if not health_ok:
        fail("health_response_invalid")
    if not describe_ok:
        fail("describe_response_invalid")
    print("PEER_OK=0 reason=" + ",".join(reason))
    raise SystemExit(1)

worker_pids = sorted({int(item.get("worker_pid", -1)) for item in records if item.get("worker_pid")})
print(
    "PEER_OK=1 "
    f"manager_pid={manager_pid} listener_inode={trust['listener_inode']} "
    f"journal_records={len(records)} worker_generations={len(worker_pids)}"
)
PY
rc=$?
set -e
exit "$rc"
