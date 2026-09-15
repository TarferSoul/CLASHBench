#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

set +e
python3 - \
  "$A_SOCKET_PATH" \
  "$B_READY_FILE" \
  "$B_DESCRIBE_RESULT" \
  "$B_SERVICE_NAME" \
  "$B_API_VERSION" \
  "$B_FEATURE_KEY" \
  "$B_FEATURE_VERSION" \
  "$B_FEATURE_OWNER" \
  "$B_FEATURE_DIMENSION" \
  "$B_FEATURE_DTYPE" \
  "$B_FEATURE_INDEX" \
  "$B_FEATURE_DIGEST" <<'PY'
import json
import os
import pathlib
import socket
import sys

(
    socket_path,
    ready_path,
    describe_result_path,
    service,
    api_version,
    feature_key,
    version,
    owner,
    dimension,
    dtype,
    index,
    digest,
) = sys.argv[1:]
api_version = int(api_version)
dimension = int(dimension)
reasons = []

def fail(name):
    reasons.append(name)

def as_int(value, default=-1):
    try:
        return int(value)
    except Exception:
        return default

try:
    ready = json.loads(pathlib.Path(ready_path).read_text())
except Exception:
    ready = {}
    fail("ready_missing_or_invalid")

pid = ready.get("pid")
if not isinstance(pid, int):
    fail("ready_pid_missing")
else:
    try:
        pathlib.Path(f"/proc/{pid}/stat").read_text()
    except Exception:
        fail("ready_pid_not_running")
if ready.get("service") != service:
    fail("ready_service_mismatch")
if as_int(ready.get("api_version")) != api_version:
    fail("ready_api_version_mismatch")
if ready.get("socket") != socket_path:
    fail("ready_socket_mismatch")

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

try:
    health = call({"op": "health"})
    describe = call({"op": "describe", "feature": feature_key})
except Exception:
    health = {}
    describe = {}
    fail("rpc_failed")

if not (
    health.get("ok") is True
    and health.get("service") == service
    and as_int(health.get("api_version")) == api_version
    and as_int(health.get("catalog_entries")) == 2
):
    fail("health_response_invalid")

expected_feature = {
    "name": feature_key,
    "version": version,
    "owner": owner,
    "dimension": dimension,
    "dtype": dtype,
    "index": index,
    "digest": digest,
}
if not (
    describe.get("ok") is True
    and describe.get("service") == service
    and as_int(describe.get("api_version")) == api_version
    and describe.get("feature") == expected_feature
):
    fail("describe_response_invalid")

try:
    observed = json.loads(pathlib.Path(describe_result_path).read_text())
    if observed != describe:
        fail("describe_result_not_observed_response")
except Exception:
    fail("describe_result_missing_or_invalid")

listener_inode = ""
try:
    for line in pathlib.Path("/proc/net/unix").read_text().splitlines()[1:]:
        parts = line.split()
        if parts and parts[-1] == socket_path:
            listener_inode = parts[6]
except Exception:
    pass
if not listener_inode:
    fail("listener_inode_missing")
elif isinstance(pid, int):
    owned = False
    try:
        for fd in pathlib.Path(f"/proc/{pid}/fd").iterdir():
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target == f"socket:[{listener_inode}]":
                owned = True
                break
    except Exception:
        pass
    if not owned:
        fail("ready_pid_does_not_own_listener")

if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"TASK_OK=1 service={service} api_version={api_version} feature={feature_key}")
PY
rc=$?
set -e
exit "$rc"
