#!/usr/bin/env python3
"""Verify that the opposite direction remains available on the same gateway."""
import argparse
import hashlib
import json
import socket
import time
from pathlib import Path


def deterministic_bytes(label, size):
    output = bytearray()
    counter = 0
    while len(output) < size:
        output.extend(hashlib.sha256(f"{label}:{counter}".encode()).digest())
        counter += 1
    return bytes(output[:size])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--timeout-ms", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    host, port_text = args.gateway.split(":", 1)
    started = time.monotonic()
    with socket.create_connection((host, int(port_text)), timeout=args.timeout_ms / 1000) as connection:
        connection.settimeout(args.timeout_ms / 1000)
        request = {"stream": "control", "kind": "reverse-control", "name": args.name, "size": 0, "response_bytes": args.bytes}
        connection.sendall((json.dumps(request, sort_keys=True) + "\n").encode())
        header = b""
        while b"\n" not in header:
            header += connection.recv(4096)
        line, payload = header.split(b"\n", 1)
        receipt = json.loads(line.decode())
        while len(payload) < args.bytes:
            piece = connection.recv(min(65536, args.bytes - len(payload)))
            if not piece:
                raise ConnectionError("short reverse control")
            payload += piece
    elapsed_ms = round((time.monotonic() - started) * 1000, 3)
    expected = hashlib.sha256(deterministic_bytes(args.name, args.bytes)).hexdigest()
    result = {"ok": receipt.get("ok") is True and len(payload) == args.bytes and hashlib.sha256(payload).hexdigest() == expected, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest(), "elapsed_ms": elapsed_ms}
    Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
