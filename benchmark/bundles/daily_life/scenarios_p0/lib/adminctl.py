#!/usr/bin/env python3
"""Root-only reset/snapshot helper used by deterministic oracle scripts."""

import json
import os
import socket
import sys


path = os.environ.get("SOCKET_PATH", "/run/everyday_conflict/service.sock")
command = sys.argv[1]
payload = {"op": "admin_reset", "scenario": sys.argv[2]} if command == "reset" else {"op": "admin_snapshot"}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    client.sendall((json.dumps(payload) + "\n").encode())
    data = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
result = json.loads(data)
print(json.dumps(result, ensure_ascii=False, sort_keys=True))
if not result.get("ok"):
    raise SystemExit(1)
