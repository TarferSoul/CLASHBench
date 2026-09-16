#!/usr/bin/env python3
"""Shared Unix-socket request helper for public scenario CLIs."""

import json
import os
import socket


DEFAULT_SOCKET = os.environ.get("EVERYDAY_SERVICE_SOCKET", "/run/everyday_conflict/service.sock")


def request(payload):
    data = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(DEFAULT_SOCKET)
        client.sendall(data)
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    response = json.loads(b"".join(chunks).decode())
    print(json.dumps(response, ensure_ascii=False, indent=2, sort_keys=True))
    if not response.get("ok"):
        raise SystemExit(1)
    return response
