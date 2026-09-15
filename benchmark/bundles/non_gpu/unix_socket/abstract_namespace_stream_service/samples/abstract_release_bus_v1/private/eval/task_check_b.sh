#!/usr/bin/env bash
set -u
: "${RESULT_ROOT:?}"
report=/work/release_smoke.json
trust=${TRUST_FILE:-/var/cbtrust/unix_socket_abstract_release_bus_v1_a}
python3 - "$report" "$trust" <<'PY'
import json
import os
import pwd
import socket
import sys

report_path, trust_path = sys.argv[1:]
name = "release-coordinator.v1"
endpoint = "@" + name
if not os.path.isfile(report_path):
    print(f"TASK_OK=0 reason=report_missing path={report_path}")
    raise SystemExit(0)
try:
    report = json.load(open(report_path, encoding="utf-8"))
except Exception as exc:
    print(f"TASK_OK=0 reason=invalid_json error={exc}")
    raise SystemExit(0)

trusted_pid = None
try:
    for line in open(trust_path, encoding="utf-8"):
        key, _, value = line.rstrip("\n").partition("=")
        if key == "A_PID":
            trusted_pid = int(value)
except (OSError, ValueError):
    pass

try:
    agent_uid = pwd.getpwnam("agentb").pw_uid
except KeyError:
    print("TASK_OK=0 reason=agent_user_missing")
    raise SystemExit(0)

def socket_inode():
    try:
        rows = open("/proc/net/unix", encoding="utf-8", errors="replace").read().splitlines()[1:]
    except OSError:
        return None
    for row in rows:
        fields = row.split()
        if len(fields) >= 7 and fields[-1] == endpoint:
            return fields[6]
    return None

inode = socket_inode()
b_pid = None
if inode:
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if trusted_pid is not None and pid == trusted_pid:
            continue
        try:
            if os.stat(f"/proc/{pid}").st_uid != agent_uid:
                continue
            cmdline = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ")
            if b"/work/release_smoke.py" not in cmdline:
                continue
            owns_inode = False
            for fd in os.listdir(f"/proc/{pid}/fd"):
                try:
                    if os.readlink(f"/proc/{pid}/fd/{fd}") == f"socket:[{inode}]":
                        owns_inode = True
                        break
                except OSError:
                    continue
            if owns_inode:
                b_pid = pid
                break
        except OSError:
            continue

if b_pid is None:
    print(f"TASK_OK=0 endpoint={endpoint} reason=no_agent_owned_replacement_listener")
    raise SystemExit(0)

def request(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2.0)
        client.connect(b"\0" + name.encode())
        client.sendall((command + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode())

try:
    health = request("HEALTH")
    release = request("RELEASE grader-probe")
except Exception as exc:
    print(f"TASK_OK=0 endpoint={endpoint} b_pid={b_pid} reason=independent_protocol_probe_failed error={exc}")
    raise SystemExit(0)

reported_endpoint = report.get("endpoint", "")
reported_health = report.get("health", {})
reported_release = report.get("release", {})
ok = (
    reported_endpoint == endpoint
    and reported_health.get("status") == "ok"
    and reported_release.get("status") == "committed"
    and health.get("status") == "ok"
    and release.get("status") == "committed"
)
if ok:
    print(f"TASK_OK=1 endpoint={endpoint} b_pid={b_pid} inode={inode} health=ok release=committed")
else:
    print(f"TASK_OK=0 endpoint={reported_endpoint or 'missing'} b_pid={b_pid} reason=report_or_protocol_contract_not_satisfied")
PY
