#!/usr/bin/env python3
"""Small release-coordination RPC service using a Linux abstract socket."""

import json
import os
import signal
import socket
import sys
import time

NAME = os.environ.get("SOCKET_NAME", "release-coordinator.v1")
STATE_PATH = os.environ.get("STATE_PATH", "/tmp/release-coordinator-state.json")
ADDRESS = b"\0" + NAME.encode("utf-8")
running = True
server = None
SOCKET_INODE = ""


def write_state(requests, last_release=""):
    with open(f"/proc/{os.getpid()}/stat", encoding="utf-8") as handle:
        fields = handle.read().split()
    payload = {
        "pid": os.getpid(),
        "start_ticks": fields[21],
        "requests": requests,
        "last_release": last_release,
        "socket_inode": SOCKET_INODE,
        "updated_at": time.time(),
    }
    temp = STATE_PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
        handle.write("\n")
    os.replace(temp, STATE_PATH)


def stop(_signum, _frame):
    global running
    running = False
    if server is not None:
        try:
            server.close()
        except OSError:
            pass


def response_for(line, requests):
    command = line.strip()
    if command == "HEALTH":
        return {"status": "ok", "service": "release-coordinator", "requests": requests}
    if command.startswith("RELEASE ") and command[8:].strip():
        return {"status": "committed", "release": command[8:].strip(), "requests": requests}
    return {"status": "error", "error": "unsupported command"}


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
os.makedirs(os.path.dirname(STATE_PATH) or ".", exist_ok=True)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.settimeout(0.5)
server.bind(ADDRESS)
server.listen(8)
for fd_name in os.listdir(f"/proc/{os.getpid()}/fd"):
    try:
        target = os.readlink(f"/proc/{os.getpid()}/fd/{fd_name}")
    except OSError:
        continue
    if target.startswith("socket:["):
        candidate = target[8:-1]
        SOCKET_INODE = candidate
        break
requests = 0
write_state(requests)
while running:
    try:
        conn, _ = server.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    with conn:
        conn.settimeout(2.0)
        try:
            stream = conn.makefile("rwb")
            line = stream.readline(4096).decode("utf-8", "replace")
            if line:
                requests += 1
                result = response_for(line, requests)
                write_state(requests, result.get("release", ""))
                stream.write((json.dumps(result, sort_keys=True) + "\n").encode("utf-8"))
                stream.flush()
        except (OSError, UnicodeError):
            pass
if server is not None:
    try:
        server.close()
    except OSError:
        pass
sys.exit(0)
